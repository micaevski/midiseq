package seq

import "core:math"
import "core:math/rand"
import "core:mem"


// =============================================================================
// Public API
// =============================================================================

DEFAULT_POOL_BYTES :: 100_000 * size_of(Runtime_Event)
NAMES_ARENA_BYTES :: 16 * 1024

STEPS_PER_BEAT :: 4096
BEAT_QUANTUM :: f32(1.0) / f32(STEPS_PER_BEAT)


Source_Index :: distinct u32
Runtime_Index :: distinct u32
NIL_SOURCE :: Source_Index(0)
NIL_RUNTIME :: Runtime_Index(0)

// Caller-supplied note dispatch. The sequencer calls these whenever a
// note crosses an on/off boundary. `beat` is the musical time the
// event was scheduled at.
Sink :: struct {
	user:     rawptr,
	note_on:  proc(user: rawptr, channel, number, velocity: i32, beat: f32),
	note_off: proc(user: rawptr, channel, number: i32, beat: f32),
	cc:       proc(user: rawptr, channel, number, value: i32, beat: f32),
}


// Opaque handle exported as the package's public sequencer type.
Sequencer_Handle :: ^Sequencer


// Per-tick error state. Cleared on each `tick`/`start` and populated
// as conditions arise. Inspect via `sequencer_runtime_error`.
Runtime_Error :: struct {
	pool_exhausted: bool, // a tick had to drop events because the pool was full
	empty:          bool, // start was called but the sequencer has no root
}


// Snapshot of how full the sequencer's preallocated pools are.
// Inspect via `sequencer_memory`.
Memory_Status :: struct {
	runtime_in_use:   int,
	runtime_capacity: int,
	source_in_use:    int,
	source_capacity:  int,
}


make_sequencer :: proc(sink: Sink, pool_bytes: int = DEFAULT_POOL_BYTES) -> Sequencer_Handle {
	source_capacity := pool_bytes / size_of(Source_Event)
	runtime_capacity := pool_bytes / size_of(Runtime_Event)
	s := new(Sequencer)
	s.source = make_source_store(source_capacity)
	runtime_pool_init(&s.runtime_pool, runtime_capacity)
	s.names = make_names()
	s.sink = sink
	return s
}


destroy_sequencer :: proc(s: Sequencer_Handle) {
	delete(s.source)
	runtime_pool_destroy(&s.runtime_pool)
	destroy_names(&s.names)
	free(s)
}

@(private)
reset_runtime_state :: proc(sequencer: Sequencer_Handle) {
	sequencer.beat = 0
	sequencer.runtime_error = {}

	// Wipe the runtime pool — no need to walk-and-free individual events.
	runtime_pool_reset(&sequencer.runtime_pool)
	sequencer.active_head = NIL_RUNTIME
	sequencer.active_tail = NIL_RUNTIME
	sequencer.playing_notes = {}

	for ch in 0 ..< 16 do for n in 0 ..< 128 do sequencer.last_emit_beat[ch][n] = math.inf_f32(-1)
}


start :: proc(sequencer: Sequencer_Handle) {

	reset_runtime_state(sequencer)

	if sequencer.source_root == NIL_SOURCE {
		sequencer.runtime_error.empty = true
		return
	}

	source := source_get(&sequencer.source, sequencer.source_root)
	source_timeline := source.kind.(Source_Timeline)

	root_idx := runtime_alloc(&sequencer.runtime_pool)
	root_event := runtime_get(&sequencer.runtime_pool, root_idx)
	root_event.beat = 0
	root_event.kind = Runtime_Timeline {
		cursor        = source_timeline.first,
		source_idx    = sequencer.source_root,
		channel       = 0,
		transposition = source_timeline.transposition,
		rate          = source_timeline.rate,
		velocity      = sample_range(source_timeline.velocity),
		scale         = source_timeline.scale,
	}
	root_event.active_next = NIL_RUNTIME
	root_event.parent = NIL_RUNTIME

	sequencer.active_head = root_idx
	sequencer.active_tail = root_idx
}


tick :: proc(sequencer: Sequencer_Handle, beat: f32) {
	sequencer.runtime_error = {}
	sequencer.beat = beat

	finished_head := NIL_RUNTIME
	previous_index := NIL_RUNTIME
	current_index := sequencer.active_head
	for current_index != NIL_RUNTIME {
		event := runtime_get(&sequencer.runtime_pool, current_index)

		parent_finished := false
		if event.parent != NIL_RUNTIME {
			parent_event := runtime_get(&sequencer.runtime_pool, event.parent)
			parent_timeline := parent_event.kind.(Runtime_Timeline)
			parent_is_root := parent_timeline.source_idx == sequencer.source_root
			parent_finished = parent_timeline.cursor == NIL_SOURCE && !parent_is_root
		}

		finished := false
		switch k in event.kind {
		case Runtime_Note:
			if parent_finished do event.parent = NIL_RUNTIME
			if event.beat + k.duration <= sequencer.beat {
				if k.channel >= 0 && k.channel < 16 && k.number >= 0 && k.number < 128 {
					if sequencer.playing_notes[k.channel][k.number] == current_index {
						sequencer.sink.note_off(
							&sequencer.sink,
							k.channel,
							k.number,
							event.beat + k.duration,
						)
						sequencer.playing_notes[k.channel][k.number] = NIL_RUNTIME
					}
				}
				finished = true
			}
		case Runtime_Timeline:
			if parent_finished {
				(&event.kind.(Runtime_Timeline)).cursor = NIL_SOURCE
				finished = true
			} else {
				local_beat := quantize((sequencer.beat - event.beat) * k.rate)
				spawn_head, spawn_tail := play_timeline(sequencer, current_index, local_beat)
				if spawn_head != NIL_RUNTIME {
					if sequencer.active_tail == NIL_RUNTIME {
						sequencer.active_head = spawn_head
					} else {
						runtime_get(&sequencer.runtime_pool, sequencer.active_tail).active_next =
							spawn_head
					}
					sequencer.active_tail = spawn_tail
				}
				is_root := k.source_idx == sequencer.source_root
				finished = event.kind.(Runtime_Timeline).cursor == NIL_SOURCE && !is_root
			}
		}

		next_index := event.active_next
		if finished {
			if previous_index == NIL_RUNTIME {
				sequencer.active_head = next_index
			} else {
				runtime_get(&sequencer.runtime_pool, previous_index).active_next = next_index
			}
			if current_index == sequencer.active_tail {
				sequencer.active_tail = previous_index
			}
			event.active_next = finished_head
			finished_head = current_index
		} else {
			previous_index = current_index
		}
		current_index = next_index
	}

	current_index = finished_head
	for current_index != NIL_RUNTIME {
		next_index := runtime_get(&sequencer.runtime_pool, current_index).active_next
		runtime_free(&sequencer.runtime_pool, current_index)
		current_index = next_index
	}
}


finished :: proc(sequencer: Sequencer_Handle) -> bool {
	return sequencer.active_head == NIL_RUNTIME
}


silence :: proc(sequencer: Sequencer_Handle) {
	for ch in 0 ..< 16 {
		for num in 0 ..< 128 {
			if sequencer.playing_notes[ch][num] != NIL_RUNTIME {
				sequencer.sink.note_off(&sequencer.sink, i32(ch), i32(num), sequencer.beat)
				sequencer.playing_notes[ch][num] = NIL_RUNTIME
			}
		}
	}
}


// Adapt the running sequencer to a new source; runtime events keep
// playing if their target still exists by name, retire otherwise.
adapt_to_source :: proc(sequencer: Sequencer_Handle, parser: ^Parser, new_root: Source_Index) {
	current_index := sequencer.active_head
	for current_index != NIL_RUNTIME {
		event := runtime_get(&sequencer.runtime_pool, current_index)
		switch _ in event.kind {
		case Runtime_Note:
			n := &event.kind.(Runtime_Note)
			if new_idx, ok := remap_idx(n.parent_source_idx, &sequencer.names, &parser.names); ok {
				n.parent_source_idx = new_idx
			} else {
				// Mark note for retirement by setting time in the past.
				event.beat = math.inf_f32(-1)
			}
		case Runtime_Timeline:
			t := &event.kind.(Runtime_Timeline)
			if new_parent, ok := remap_idx(t.source_idx, &sequencer.names, &parser.names); ok {
				old_first :=
					source_get(&sequencer.source, t.source_idx).kind.(Source_Timeline).first
				new_first := source_get(&parser.source, new_parent).kind.(Source_Timeline).first
				new_cursor := remap_cursor(
					&sequencer.source,
					&parser.source,
					old_first,
					new_first,
					t.cursor,
				)
				if new_cursor == NIL_SOURCE {
					new_cursor = first_cursor_after(
						&parser.source,
						new_first,
						(sequencer.beat - event.beat) * t.rate,
					)
				}
				t.source_idx = new_parent
				t.cursor = new_cursor
			} else {
				t.cursor = NIL_SOURCE
			}
		}
		current_index = event.active_next
	}

	parser.source, sequencer.source = sequencer.source, parser.source
	parser.names, sequencer.names = sequencer.names, parser.names
	sequencer.source_root = new_root
	rand.reset_u64(parser.seed)
}


// --- accessors -------------------------------------------------------------

sequencer_beat :: proc(s: Sequencer_Handle) -> f32 {
	return s.beat
}

sequencer_runtime_error :: proc(s: Sequencer_Handle) -> Runtime_Error {
	return s.runtime_error
}

sequencer_memory :: proc(s: Sequencer_Handle) -> Memory_Status {
	return Memory_Status {
		runtime_in_use = int(s.runtime_pool.in_use),
		runtime_capacity = runtime_pool_capacity(&s.runtime_pool),
		source_in_use = len(s.source) - 1,
		source_capacity = cap(s.source) - 1,
	}
}


// =============================================================================
// Internals
// =============================================================================

@(private)
Sequencer :: struct {
	beat:           f32,
	source_root:    Source_Index,
	active_head:    Runtime_Index,
	active_tail:    Runtime_Index,
	source:         [dynamic]Source_Event,
	runtime_pool:   Runtime_Pool,
	sink:           Sink,
	names:          Names,
	playing_notes:  [16][128]Runtime_Index,
	last_emit_beat: [16][128]f32,
	runtime_error:  Runtime_Error,
}


Note_Number :: bit_field u32 {
	pitch1:    u8   | 7,
	octave1:   u8   | 7,
	pitch2:    u8   | 7,
	octave2:   u8   | 7,
	is_degree: bool | 1,
}


I32_Range :: struct {
	lo: i32,
	hi: i32,
}

Source_Note :: struct {
	number:   Note_Number,
	velocity: I32_Range, // 0..127; sampled on each emit
	duration: f32, // in beats; note-off fires at start_beat + duration
}

MOD_COUNT :: 4

Mod_Op_Kind :: enum u8 {
	Nop,
	Set,
	Add,
}

Mod_Op :: struct {
	kind:  Mod_Op_Kind,
	value: i32,
}

Source_Timeline :: struct {
	first:         Source_Index,
	transposition: Transposition,
	rate:          f32, // time-scale multiplier
	velocity:      I32_Range, // additive offset applied to child notes; sampled on each spawn
	mod_ops:       [MOD_COUNT]Mod_Op, // each mod register: nop / set / add applied at spawn
	scale:         Scale, // zero-value (None) means "no scale set"
	channel:       Maybe(u8),
	free:          bool, // ref: spawn detaches from parent's lifecycle
}

Source_Fork :: struct {
	get:        Predicate_Getter,
	op:         Predicate_Op,
	constant:   f32,
	else_first: Source_Index,
}

Source_CC :: struct {
	number:  i32, // 0..127
	value:   I32_Range, // literal/range component sampled per emit
	mod_idx: i8, // -1 = no mod ref; else 0..MOD_COUNT-1, value adds mods[mod_idx]
	channel: Maybe(u8),
}

Source_Kind :: union {
	Source_Note,
	Source_Timeline,
	Source_Fork,
	Source_CC,
}

Source_Event :: struct {
	beat:   f32,
	chance: i32, // 0..100; probability of firing. 100 = always.
	kind:   Source_Kind,
	next:   Source_Index,
}


Runtime_Note :: struct {
	number:            i32,
	duration:          f32,
	channel:           i32,
	parent_source_idx: Source_Index,
}

Runtime_Timeline :: struct {
	cursor:        Source_Index,
	source_idx:    Source_Index,
	transposition: Transposition,
	rate:          f32,
	velocity:      i32,
	mods:          [MOD_COUNT]i32,
	scale:         Scale,
	channel:       u8,
}

Runtime_Kind :: union {
	Runtime_Note,
	Runtime_Timeline,
}


Predicate_Getter :: proc(t: ^Runtime_Timeline) -> f32
Predicate_Op :: proc(value, constant: f32) -> bool

get_trans_semitones :: proc(t: ^Runtime_Timeline) -> f32 {
	return f32(
		i32(t.transposition.semitones) +
		degrees_to_semitones(i32(t.transposition.degrees), t.scale),
	)
}
get_rate :: proc(t: ^Runtime_Timeline) -> f32 {return t.rate}

op_gt :: proc(a, b: f32) -> bool {return a > b}
op_lt :: proc(a, b: f32) -> bool {return a < b}
op_eq :: proc(a, b: f32) -> bool {return a == b}
op_neq :: proc(a, b: f32) -> bool {return a != b}
op_geq :: proc(a, b: f32) -> bool {return a >= b}
op_leq :: proc(a, b: f32) -> bool {return a <= b}

Runtime_Event :: struct {
	beat:        f32,
	kind:        Runtime_Kind,
	active_next: Runtime_Index,
	parent:      Runtime_Index,
}


Names :: struct {
	lookup:    map[Source_Index]string,
	by_name:   map[string]Source_Index,
	arena:     mem.Arena,
	arena_buf: []byte,
}


quantize :: proc(t: f32) -> f32 {
	return math.round(t * f32(STEPS_PER_BEAT)) / f32(STEPS_PER_BEAT)
}


sample_range :: proc(r: I32_Range) -> i32 {
	if r.hi <= r.lo do return r.lo
	return r.lo + i32(rand.int_max(int(r.hi - r.lo + 1)))
}


make_source_store :: proc(capacity: int) -> [dynamic]Source_Event {
	return make([dynamic]Source_Event, 1, capacity) // len=1 reserves slot 0
}

source_store_reset :: proc(s: ^[dynamic]Source_Event) {
	resize(s, 1)
	s[0] = {}
}

source_alloc :: proc(s: ^[dynamic]Source_Event) -> Source_Index {
	if len(s) >= cap(s) do return NIL_SOURCE
	append(s, Source_Event{})
	return Source_Index(len(s) - 1)
}

source_get :: proc(s: ^[dynamic]Source_Event, index: Source_Index) -> ^Source_Event {
	return &s[index]
}


make_names :: proc() -> Names {
	n := Names{}
	n.arena_buf = make([]byte, NAMES_ARENA_BYTES)
	mem.arena_init(&n.arena, n.arena_buf)
	n.lookup = make(map[Source_Index]string, 32)
	n.by_name = make(map[string]Source_Index, 16)
	return n
}

destroy_names :: proc(n: ^Names) {
	delete(n.lookup)
	delete(n.by_name)
	delete(n.arena_buf)
	n^ = {}
}

names_reset :: proc(n: ^Names) {
	clear(&n.lookup)
	clear(&n.by_name)
	mem.arena_free_all(&n.arena)
}


add_source_event_chain :: proc(
	s: ^[dynamic]Source_Event,
	head: ^Source_Index,
	tail: ^Source_Index,
	event: Source_Event,
) -> Source_Index {
	new_idx := source_alloc(s)
	if new_idx == NIL_SOURCE do return NIL_SOURCE

	new_event := source_get(s, new_idx)
	new_event^ = event

	current_idx := head^
	prev_idx := NIL_SOURCE
	for current_idx != NIL_SOURCE {
		current_event := source_get(s, current_idx)
		if current_event.beat > event.beat do break
		prev_idx = current_idx
		current_idx = current_event.next
	}

	new_event.next = current_idx
	if prev_idx == NIL_SOURCE {
		head^ = new_idx
	} else {
		source_get(s, prev_idx).next = new_idx
	}
	if current_idx == NIL_SOURCE {
		tail^ = new_idx
	}

	return new_idx
}

add_source_event :: proc(
	s: ^[dynamic]Source_Event,
	parent: Source_Index,
	event: Source_Event,
) -> Source_Index {
	parent_event := source_get(s, parent)
	timeline := &parent_event.kind.(Source_Timeline)
	tail_dummy: Source_Index = NIL_SOURCE
	return add_source_event_chain(s, &timeline.first, &tail_dummy, event)
}


@(private)
remap_idx :: proc(
	old_idx: Source_Index,
	old_names: ^Names,
	new_names: ^Names,
) -> (
	Source_Index,
	bool,
) {
	name, has_name := old_names.lookup[old_idx]
	if !has_name do return NIL_SOURCE, false
	new_idx, exists := new_names.by_name[name]
	if !exists do return NIL_SOURCE, false
	return new_idx, true
}


@(private)
remap_cursor :: proc(
	old_src, new_src: ^[dynamic]Source_Event,
	old_head, new_head: Source_Index,
	target: Source_Index,
) -> Source_Index {
	visited := make(map[Source_Index]bool, 16, context.temp_allocator)
	defer delete(visited)
	return remap_walk(old_src, new_src, old_head, new_head, target, &visited)
}

@(private)
first_cursor_after :: proc(
	s: ^[dynamic]Source_Event,
	head: Source_Index,
	local_time: f32,
) -> Source_Index {
	walker := head
	for walker != NIL_SOURCE {
		ev := source_get(s, walker)
		if ev.beat > local_time do return walker
		walker = ev.next
	}
	return NIL_SOURCE
}

@(private)
remap_walk :: proc(
	old_src, new_src: ^[dynamic]Source_Event,
	old_walker, new_walker: Source_Index,
	target: Source_Index,
	visited: ^map[Source_Index]bool,
) -> Source_Index {
	old_w := old_walker
	new_w := new_walker
	for old_w != NIL_SOURCE && new_w != NIL_SOURCE {
		if visited[old_w] do break
		visited[old_w] = true
		old_ev := source_get(old_src, old_w)
		new_ev := source_get(new_src, new_w)
		if old_ev.beat != new_ev.beat do return NIL_SOURCE
		old_fork, old_is_fork := old_ev.kind.(Source_Fork)
		new_fork, new_is_fork := new_ev.kind.(Source_Fork)
		if old_is_fork != new_is_fork do return NIL_SOURCE
		if old_w == target do return new_w
		if old_is_fork {
			result := remap_walk(
				old_src,
				new_src,
				old_fork.else_first,
				new_fork.else_first,
				target,
				visited,
			)
			if result != NIL_SOURCE do return result
		}
		old_w = old_ev.next
		new_w = new_ev.next
	}
	return NIL_SOURCE
}


@(private)
resolve_note :: proc(
	note: Source_Note,
	timeline: ^Runtime_Timeline,
	beat: f32,
	last_emit_beat: ^[16][128]f32,
) -> (
	channel, number: i32,
	duration: f32,
	ok: bool,
) {
	channel = i32(timeline.channel)
	raw := resolve_note_pitch(note.number, timeline.scale)
	number = raw + i32(timeline.transposition.semitones)
	number = shift_in_scale(
		number,
		i32(timeline.transposition.degrees),
		i32(timeline.scale.root),
		scale_offsets(timeline.scale.kind),
	)
	if channel < 0 || channel >= 16 || number < 0 || number >= 128 do return
	if beat <= last_emit_beat[channel][number] + BEAT_QUANTUM do return
	duration = max(quantize(note.duration / timeline.rate), BEAT_QUANTUM)
	ok = true
	return
}


@(private)
resolve_note_pitch :: proc(n: Note_Number, scale: Scale) -> i32 {
	pos_lo, pos_hi: i32
	if n.is_degree {
		size := scale_size(scale)
		pos_lo = i32(n.octave1) * size + i32(n.pitch1) - 1
		pos_hi = i32(n.octave2) * size + i32(n.pitch2) - 1
	} else {
		pos_lo = i32(n.pitch1)
		pos_hi = i32(n.pitch2)
	}
	if pos_hi < pos_lo do pos_lo, pos_hi = pos_hi, pos_lo

	pos := pos_lo
	if pos_hi != pos_lo do pos += i32(rand.int_max(int(pos_hi - pos_lo + 1)))

	return n.is_degree ? midi_from_pos(pos, scale) : pos
}


/*
Walk the timeline event and create runtime events for all source events that fall within the current tick, fire notes immediately.
Returns a linked list of active events (head and tail).
*/
play_timeline :: proc(
	sequencer: Sequencer_Handle,
	timeline_event_idx: Runtime_Index,
	local_time: f32,
) -> (
	spawn_head: Runtime_Index,
	spawn_tail: Runtime_Index,
) {
	timeline_event := runtime_get(&sequencer.runtime_pool, timeline_event_idx)
	timeline := &timeline_event.kind.(Runtime_Timeline)

	spawn_head = NIL_RUNTIME
	spawn_tail = NIL_RUNTIME

	for timeline.cursor != NIL_SOURCE {
		cursor_event := source_get(&sequencer.source, timeline.cursor)

		if fork, is_fork := cursor_event.kind.(Source_Fork); is_fork {
			timeline.cursor =
				fork.op(fork.get(timeline), fork.constant) ? cursor_event.next : fork.else_first
			continue
		}

		if cursor_event.beat > local_time do break

		if cursor_event.chance < 100 {
			roll := i32(rand.int_max(100))
			if roll >= cursor_event.chance {
				timeline.cursor = cursor_event.next
				continue
			}
		}

		beat := quantize(cursor_event.beat / timeline.rate + timeline_event.beat)

		new_idx: Runtime_Index = NIL_RUNTIME
		#partial switch k in cursor_event.kind {
		case Source_Note:
			channel, number, duration, ok := resolve_note(
				k,
				timeline,
				beat,
				&sequencer.last_emit_beat,
			)
			if !ok {
				timeline.cursor = cursor_event.next
				continue
			}
			new_idx = runtime_alloc(&sequencer.runtime_pool)
			if new_idx == NIL_RUNTIME {
				// Pool exhausted; skip this event so timeline can keep running and the pool could be freed.
				sequencer.runtime_error.pool_exhausted = true
				timeline.cursor = cursor_event.next
				continue
			}
			runtime_event := runtime_get(&sequencer.runtime_pool, new_idx)
			runtime_event.beat = beat
			runtime_event.active_next = NIL_RUNTIME
			runtime_event.parent = timeline_event_idx
			runtime_event.kind = Runtime_Note {
				number            = number,
				duration          = duration,
				channel           = channel,
				parent_source_idx = timeline.source_idx,
			}
			if sequencer.playing_notes[channel][number] != NIL_RUNTIME {
				sequencer.sink.note_off(&sequencer.sink, channel, number, beat)
			}
			sequencer.playing_notes[channel][number] = new_idx
			sequencer.last_emit_beat[channel][number] = beat
			sequencer.sink.note_on(
				&sequencer.sink,
				channel,
				number,
				clamp(sample_range(k.velocity) + timeline.velocity, 0, 127),
				beat,
			)

		case Source_Timeline:
			new_idx = runtime_alloc(&sequencer.runtime_pool)
			if new_idx == NIL_RUNTIME {
				sequencer.runtime_error.pool_exhausted = true
				timeline.cursor = cursor_event.next
				continue
			}
			parent := timeline_event_idx
			if k.free do parent = timeline_event.parent
			child_mods := timeline.mods
			for i in 0 ..< MOD_COUNT {
				op := k.mod_ops[i]
				switch op.kind {
				case .Nop:
				case .Set:
					child_mods[i] = op.value
				case .Add:
					child_mods[i] += op.value
				}
			}
			runtime_event := runtime_get(&sequencer.runtime_pool, new_idx)
			runtime_event.beat = beat
			runtime_event.active_next = NIL_RUNTIME
			runtime_event.parent = parent
			runtime_event.kind = Runtime_Timeline {
				cursor = k.first,
				source_idx = timeline.cursor,
				channel = k.channel.? or_else timeline.channel,
				transposition = Transposition {
					semitones = i16(
						clamp(
							i32(k.transposition.semitones) + i32(timeline.transposition.semitones),
							-127,
							127,
						),
					),
					degrees = i16(
						clamp(
							i32(k.transposition.degrees) + i32(timeline.transposition.degrees),
							-127,
							127,
						),
					),
				},
				rate = clamp(k.rate * timeline.rate, 1.0 / 1024.0, 1024.0),
				velocity = clamp(sample_range(k.velocity) + timeline.velocity, -127, 127),
				mods = child_mods,
				scale = k.scale.kind != .None ? k.scale : timeline.scale,
			}

		case Source_CC:
			channel := i32(k.channel.? or_else timeline.channel)
			if channel >= 0 && channel < 16 && k.number >= 0 && k.number < 128 {
				mod_value: i32 = 0
				if k.mod_idx >= 0 && k.mod_idx < MOD_COUNT {
					mod_value = timeline.mods[k.mod_idx]
				}
				value := clamp(sample_range(k.value) + mod_value, 0, 127)
				sequencer.sink.cc(&sequencer.sink, channel, k.number, value, beat)
			}
			timeline.cursor = cursor_event.next
			continue
		}

		if spawn_tail == NIL_RUNTIME {
			spawn_head = new_idx
		} else {
			runtime_get(&sequencer.runtime_pool, spawn_tail).active_next = new_idx
		}
		spawn_tail = new_idx

		timeline.cursor = cursor_event.next
	}

	return
}
