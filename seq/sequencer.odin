package seq

import "core:math"
import "core:mem"


DEFAULT_POOL_BYTES :: 1_000_000 * size_of(Runtime_Event)
NAMES_ARENA_BYTES :: 16 * 1024

Source_Index :: distinct u32
Runtime_Index :: distinct u32
NIL_SOURCE :: Source_Index(0)
NIL_RUNTIME :: Runtime_Index(0)

Note :: struct {
	number:   i32, // MIDI note, 0..127
	velocity: i32, // 0..127
	duration: f32, // in beats; note-off fires at start_beat + duration
}

Source_Timeline :: struct {
	first:         Source_Index,
	channel:       i32,
	transposition: i32, // semitones
	rate:          f32, // time-scale multiplier
	free:          bool, // ref: spawn detaches from parent's lifecycle
}

Source_Kind :: union {
	Note,
	Source_Timeline,
}

Source_Event :: struct {
	beat:   f32,
	chance: i32, // 0..100; probability of firing. 100 = always.
	kind:   Source_Kind,
	prev:   Source_Index,
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
	channel:       i32,
	transposition: i32,
	rate:          f32,
}

Runtime_Kind :: union {
	Runtime_Note,
	Runtime_Timeline,
}

Runtime_Event :: struct {
	beat:        f32,
	kind:        Runtime_Kind,
	active_next: Runtime_Index,
	parent:      Runtime_Index,
}

Sink :: struct {
	user:     rawptr,
	note_on:  proc(user: rawptr, channel, number, velocity: i32),
	note_off: proc(user: rawptr, channel, number: i32),
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

Names :: struct {
	lookup:    map[Source_Index]string,
	by_name:   map[string]Source_Index,
	arena:     mem.Arena,
	arena_buf: []byte,
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


Sequencer :: struct {
	tempo:         f32,
	beat:          f32,
	source_root:   Source_Index,
	active_head:   Runtime_Index,
	active_tail:   Runtime_Index,
	finished_head: Runtime_Index,
	source:        [dynamic]Source_Event,
	runtime_pool:  Runtime_Pool,
	sink:          Sink,
	rng_state:     u32, // xorshift32; set via `SEED = N` in source
	names:         Names,
	playing_notes: [16][128]Runtime_Index,
}


make_sequencer :: proc(pool_bytes: int = DEFAULT_POOL_BYTES) -> Sequencer {
	source_capacity := pool_bytes / size_of(Source_Event)
	runtime_capacity := pool_bytes / size_of(Runtime_Event)
	sequencer := Sequencer{}
	sequencer.source = make_source_store(source_capacity)
	runtime_pool_init(&sequencer.runtime_pool, runtime_capacity)
	sequencer.names = make_names()
	return sequencer
}

destroy_sequencer :: proc(sequencer: ^Sequencer) {
	delete(sequencer.source)
	runtime_pool_destroy(&sequencer.runtime_pool)
	destroy_names(&sequencer.names)
}


add_source_event :: proc(
	s: ^[dynamic]Source_Event,
	parent: Source_Index,
	event: Source_Event,
) -> Source_Index {
	new_idx := source_alloc(s)
	if new_idx == NIL_SOURCE do return NIL_SOURCE

	new_event := source_get(s, new_idx)
	new_event^ = event

	parent_event := source_get(s, parent)
	timeline := &parent_event.kind.(Source_Timeline)

	current_idx := timeline.first
	prev_idx := NIL_SOURCE
	for current_idx != NIL_SOURCE {
		current_event := source_get(s, current_idx)
		if current_event.beat > event.beat do break
		prev_idx = current_idx
		current_idx = current_event.next
	}

	new_event.prev = prev_idx
	new_event.next = current_idx
	if prev_idx == NIL_SOURCE {
		timeline.first = new_idx
	} else {
		source_get(s, prev_idx).next = new_idx
	}
	if current_idx != NIL_SOURCE {
		source_get(s, current_idx).prev = new_idx
	}

	return new_idx
}

/*
Adapt the running sequencer to a new source, point runtime events to the new sources if they still exists. 
Retire events that belong to timeline that were removed by marking them to as finished.
*/
adapt_to_source :: proc(
	sequencer: ^Sequencer,
	new_source: ^[dynamic]Source_Event,
	new_names: ^Names,
	new_root: Source_Index,
) {
	current_index := sequencer.active_head
	for current_index != NIL_RUNTIME {
		event := runtime_get(&sequencer.runtime_pool, current_index)
		switch _ in event.kind {
		case Runtime_Note:
			n := &event.kind.(Runtime_Note)
			if new_idx, ok := remap_idx(n.parent_source_idx, &sequencer.names, new_names); ok {
				n.parent_source_idx = new_idx
			} else {
				// Mark note for retirement by setting time in the past.
				event.beat = math.inf_f32(-1)
			}
		case Runtime_Timeline:
			t := &event.kind.(Runtime_Timeline)
			if new_idx, ok := remap_idx(t.source_idx, &sequencer.names, new_names); ok {
				// If the source timeline exists, set the cursor to point the same time.
				t.source_idx = new_idx
				t.cursor = first_cursor_after(
					new_source,
					new_idx,
					(sequencer.beat - event.beat) * t.rate,
				)
			} else {
				// Mark timeline for retirement by pointing its cursor at nil.
				t.cursor = NIL_SOURCE
			}
		}
		current_index = event.active_next
	}

	//TODO: review this code. It is ablout hadnling the @play directives
	old_played := make(map[string]bool, 16, context.temp_allocator)
	if sequencer.source_root != NIL_SOURCE {
		old_root_event := source_get(&sequencer.source, sequencer.source_root)
		if t, ok := old_root_event.kind.(Source_Timeline); ok {
			walker := t.first
			for walker != NIL_SOURCE {
				if name, has := sequencer.names.lookup[walker]; has {
					old_played[name] = true
				}
				walker = source_get(&sequencer.source, walker).next
			}
		}
	}

	new_root_event := source_get(new_source, new_root)
	new_top := new_root_event.kind.(Source_Timeline)
	walker := new_top.first
	for walker != NIL_SOURCE {
		we := source_get(new_source, walker)
		next_walker := we.next
		ref_kind, is_ref := we.kind.(Source_Timeline)
		if is_ref {
			target_name, has_name := new_names.lookup[walker]
			already_played := false
			if has_name {
				_, already_played = old_played[target_name]
			}
			if !already_played {
				new_idx := runtime_alloc(&sequencer.runtime_pool)
				if new_idx != NIL_RUNTIME {
					re := runtime_get(&sequencer.runtime_pool, new_idx)
					re.beat = sequencer.beat
					re.active_next = NIL_RUNTIME
					re.parent = NIL_RUNTIME
					re.kind = Runtime_Timeline {
						cursor        = ref_kind.first,
						source_idx    = walker,
						channel       = ref_kind.channel,
						transposition = ref_kind.transposition,
						rate          = ref_kind.rate,
					}
					if sequencer.active_tail == NIL_RUNTIME {
						sequencer.active_head = new_idx
					} else {
						runtime_get(&sequencer.runtime_pool, sequencer.active_tail).active_next =
							new_idx
					}
					sequencer.active_tail = new_idx
				}
			}
		}
		walker = next_walker
	}
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
first_cursor_after :: proc(
	s: ^[dynamic]Source_Event,
	def_idx: Source_Index,
	local_time: f32,
) -> Source_Index {
	walker := source_get(s, def_idx).kind.(Source_Timeline).first
	for walker != NIL_SOURCE {
		we := source_get(s, walker)
		if we.beat > local_time do return walker
		walker = we.next
	}
	return NIL_SOURCE
}

start_sequencer :: proc(sequencer: ^Sequencer) {
	sequencer.beat = 0

	// Wipe the runtime pool — no need to walk-and-free individual events.
	sequencer.runtime_pool.count = 1
	sequencer.runtime_pool.free_head = 0

	source := source_get(&sequencer.source, sequencer.source_root)
	source_timeline := source.kind.(Source_Timeline)

	root_idx := runtime_alloc(&sequencer.runtime_pool)
	root_event := runtime_get(&sequencer.runtime_pool, root_idx)
	root_event.beat = 0
	root_event.kind = Runtime_Timeline {
		cursor        = source_timeline.first,
		source_idx    = sequencer.source_root,
		channel       = source_timeline.channel,
		transposition = source_timeline.transposition,
		rate          = source_timeline.rate,
	}
	root_event.active_next = NIL_RUNTIME
	root_event.parent = NIL_RUNTIME

	sequencer.active_head = root_idx
	sequencer.active_tail = root_idx
	sequencer.finished_head = NIL_RUNTIME
}


sequencer_tick :: proc(sequencer: ^Sequencer, dt: f32) {
	sequencer.beat += dt * sequencer.tempo / 60.0

	previous_index := NIL_RUNTIME
	current_index := sequencer.active_head
	for current_index != NIL_RUNTIME {
		event := runtime_get(&sequencer.runtime_pool, current_index)

		parent_finished := false
		if event.parent != NIL_RUNTIME {
			parent_event := runtime_get(&sequencer.runtime_pool, event.parent)
			parent_timeline := parent_event.kind.(Runtime_Timeline)
			parent_finished = parent_timeline.cursor == NIL_SOURCE
		}

		finished: bool
		switch k in event.kind {
		case Runtime_Note:
			if parent_finished do event.parent = NIL_RUNTIME
			if event.beat + k.duration <= sequencer.beat {
				if k.channel >= 0 && k.channel < 16 && k.number >= 0 && k.number < 128 {
					if sequencer.playing_notes[k.channel][k.number] == current_index {
						sequencer.sink.note_off(&sequencer.sink, k.channel, k.number)
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
				sub_local := (sequencer.beat - event.beat) * k.rate
				spawn_head, spawn_tail := play_timeline(sequencer, current_index, sub_local)
				if spawn_head != NIL_RUNTIME {
					if sequencer.active_tail == NIL_RUNTIME {
						sequencer.active_head = spawn_head
					} else {
						runtime_get(&sequencer.runtime_pool, sequencer.active_tail).active_next =
							spawn_head
					}
					sequencer.active_tail = spawn_tail
				}
				finished = event.kind.(Runtime_Timeline).cursor == NIL_SOURCE
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
			event.active_next = sequencer.finished_head
			sequencer.finished_head = current_index
		} else {
			previous_index = current_index
		}
		current_index = next_index
	}

	current_index = sequencer.finished_head
	for current_index != NIL_RUNTIME {
		next_index := runtime_get(&sequencer.runtime_pool, current_index).active_next
		runtime_free(&sequencer.runtime_pool, current_index)
		current_index = next_index
	}
	sequencer.finished_head = NIL_RUNTIME
}


sequencer_finished :: proc(sequencer: ^Sequencer) -> bool {
	return sequencer.active_head == NIL_RUNTIME
}

silence :: proc(sequencer: ^Sequencer) {
	for ch in 0 ..< 16 {
		for num in 0 ..< 128 {
			if sequencer.playing_notes[ch][num] != NIL_RUNTIME {
				sequencer.sink.note_off(&sequencer.sink, i32(ch), i32(num))
				sequencer.playing_notes[ch][num] = NIL_RUNTIME
			}
		}
	}
}

// xorshift32. Remaps 0 to a fixed non-zero so an un-seeded sequencer
// still produces a deterministic stream.
@(private)
rand_u32 :: proc(state: ^u32) -> u32 {
	if state^ == 0 do state^ = 0xdeadbeef
	x := state^
	x ~= x << 13
	x ~= x >> 17
	x ~= x << 5
	state^ = x
	return x
}


/*
Walk the timeline event and create runtime events for all source events that fall within the current tick, fire notes immediately.
Returns a linked list of active events (head and tail).
*/
play_timeline :: proc(
	sequencer: ^Sequencer,
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
		if cursor_event.beat > local_time do break

		// Evaluate chance.
		if cursor_event.chance < 100 {
			roll := i32(rand_u32(&sequencer.rng_state) % 100)
			if roll >= cursor_event.chance {
				timeline.cursor = cursor_event.next
				continue
			}
		}

		new_idx := runtime_alloc(&sequencer.runtime_pool)
		if new_idx == NIL_RUNTIME do break // pool exhausted; try again next tick

		runtime_event := runtime_get(&sequencer.runtime_pool, new_idx)
		// Translate the source-domain beat into root-time. For the root
		// timeline (rate=1, start=0) this is identity.
		runtime_event.beat = cursor_event.beat / timeline.rate + timeline_event.beat
		runtime_event.active_next = NIL_RUNTIME
		runtime_event.parent = timeline_event_idx

		switch k in cursor_event.kind {
		case Note:
			chan := timeline.channel
			if chan == -1 do chan = 0
			num := k.number + timeline.transposition
			runtime_event.kind = Runtime_Note {
				number            = num,
				duration          = k.duration / timeline.rate,
				channel           = chan,
				parent_source_idx = timeline.source_idx,
			}
			if chan >= 0 && chan < 16 && num >= 0 && num < 128 {
				if sequencer.playing_notes[chan][num] != NIL_RUNTIME {
					sequencer.sink.note_off(&sequencer.sink, chan, num)
				}
				sequencer.playing_notes[chan][num] = new_idx
			}
			sequencer.sink.note_on(&sequencer.sink, chan, num, k.velocity)
		case Source_Timeline:
			if k.free do runtime_event.parent = timeline_event.parent
			child_channel := k.channel
			if timeline.channel != -1 do child_channel = timeline.channel
			runtime_event.kind = Runtime_Timeline {
				cursor        = k.first,
				source_idx    = timeline.cursor,
				channel       = child_channel,
				transposition = k.transposition + timeline.transposition,
				rate          = k.rate * timeline.rate,
			}
		}
		if timeline.source_idx == sequencer.source_root {
			runtime_event.parent = NIL_RUNTIME
		}

		// Append (head→tail) so spawn_head stays in firing order.
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
