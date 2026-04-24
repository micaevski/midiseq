package seq


DEFAULT_POOL_BYTES :: 1_000_000 * size_of(Event)


// Distinct index types for the two pools. Index 0 is the nil sentinel for
// both, so default-zeroed fields safely mean "points to nothing".
Template_Index :: distinct u32
Runtime_Index :: distinct u32
NIL_TEMPLATE :: Template_Index(0)
NIL_RUNTIME :: Runtime_Index(0)


Note :: struct {
	number:   i32, // MIDI note, 0..127
	velocity: i32, // 0..127
	duration: f32, // in beats; note-off fires at start_beat + duration
}

// A Timeline has authored fields (first, channel, transposition, rate)
// and playback fields (cursor, active_head).
//   first       - head of the authored sibling chain (template pool).
//   cursor      - authored event to fire next (template pool).
//   active_head - head of the currently-sounding instances (runtime pool).
Timeline :: struct {
	first:         Template_Index,
	cursor:        Template_Index,
	active_head:   Runtime_Index,
	channel:       i32,
	transposition: i32, // semitones; accumulates additively from parent to child
	rate:          f32, // time-scale multiplier; accumulates multiplicatively
}

Event_Kind :: union {
	Note,
	Timeline,
}

// An Event struct is shared by both pools, but `prev`/`next` are only
// meaningful for template events (sibling chain) and `active_next` is
// only meaningful for runtime events (active chain). The other fields
// stay at their nil sentinels when unused.
Event :: struct {
	beat:        f32,
	chance:      i32, // 0..100; probability of firing. 100 = always.
	kind:        Event_Kind,
	prev:        Template_Index,
	next:        Template_Index,
	active_next: Runtime_Index,
}


// Where the sequencer sends its output. The library is deliberately
// agnostic about the actual backend — PortMidi, an in-process synth, a
// logger, whatever. A driver installs the procs and the opaque user
// pointer gets passed through on every call.
Sink :: struct {
	user:     rawptr,
	note_on:  proc(user: rawptr, channel, number, velocity: i32),
	note_off: proc(user: rawptr, channel, number: i32),
}


// The Sequencer holds two pools:
//   pool    - authored template events, written by the parser.
//   runtime - transient instances created during playback.
// `root` is the authored root (template). `runtime_root` is a fresh
// runtime clone of it, re-created every time start_sequencer is called.
Sequencer :: struct {
	tempo:        f32,
	beat:         f32,
	root:         Template_Index,
	runtime_root: Runtime_Index,
	pool:         Pool(Event),
	runtime:      Pool(Event),
	sink:         Sink,
	rng_state:    u32, // xorshift32; set via `SEED = N` in source
}


make_sequencer :: proc(pool_bytes: int = DEFAULT_POOL_BYTES) -> Sequencer {
	capacity := pool_bytes / size_of(Event)
	sequencer := Sequencer{}
	pool_init(&sequencer.pool, capacity)
	pool_init(&sequencer.runtime, capacity)
	return sequencer
}

destroy_sequencer :: proc(sequencer: ^Sequencer) {
	pool_destroy(&sequencer.pool)
	pool_destroy(&sequencer.runtime)
}


// Template-pool wrappers (parser side).
event_alloc :: proc(sequencer: ^Sequencer) -> Template_Index {
	return Template_Index(pool_alloc(&sequencer.pool))
}

event_free :: proc(sequencer: ^Sequencer, index: Template_Index) {
	pool_free(&sequencer.pool, u32(index))
}

event_get :: proc(sequencer: ^Sequencer, index: Template_Index) -> ^Event {
	return pool_get(&sequencer.pool, u32(index))
}

// Runtime-pool wrappers (playback side).
runtime_alloc :: proc(sequencer: ^Sequencer) -> Runtime_Index {
	return Runtime_Index(pool_alloc(&sequencer.runtime))
}

runtime_free :: proc(sequencer: ^Sequencer, index: Runtime_Index) {
	pool_free(&sequencer.runtime, u32(index))
}

runtime_get :: proc(sequencer: ^Sequencer, index: Runtime_Index) -> ^Event {
	return pool_get(&sequencer.runtime, u32(index))
}


// Insert `event` into the child list of the Timeline stored at `parent`,
// keeping the list sorted by beat. Ties go after existing events at the
// same beat (stable insertion). Returns the new event's index, or
// NIL_TEMPLATE if the pool is full. Panics if `parent` is not a Timeline.
add_event :: proc(sequencer: ^Sequencer, parent: Template_Index, event: Event) -> Template_Index {
	new_idx := event_alloc(sequencer)
	if new_idx == NIL_TEMPLATE do return NIL_TEMPLATE

	new_event := event_get(sequencer, new_idx)
	new_event^ = event

	parent_event := event_get(sequencer, parent)
	timeline := &parent_event.kind.(Timeline)

	current_idx := timeline.first
	prev_idx := NIL_TEMPLATE
	for current_idx != NIL_TEMPLATE {
		current_event := event_get(sequencer, current_idx)
		if current_event.beat > event.beat do break
		prev_idx = current_idx
		current_idx = current_event.next
	}

	new_event.prev = prev_idx
	new_event.next = current_idx
	if prev_idx == NIL_TEMPLATE {
		timeline.first = new_idx
	} else {
		event_get(sequencer, prev_idx).next = new_idx
	}
	if current_idx != NIL_TEMPLATE {
		event_get(sequencer, current_idx).prev = new_idx
	}

	return new_idx
}


// ===== Sequencer driver =====

// Reset the runtime pool and allocate a fresh root instance cloned from
// the authored root template. Safe to call repeatedly (Stop -> Start).
start_sequencer :: proc(sequencer: ^Sequencer) {
	sequencer.beat = 0

	// Wipe the runtime pool — no need to walk-and-free individual events.
	sequencer.runtime.count = 1
	sequencer.runtime.free_head = 0

	// Clone the authored root as a fresh runtime instance.
	template := event_get(sequencer, sequencer.root)
	template_tl := template.kind.(Timeline)

	root_idx := runtime_alloc(sequencer)
	root_event := runtime_get(sequencer, root_idx)
	root_event.beat = 0
	root_event.kind = Timeline {
		first         = template_tl.first,
		cursor        = template_tl.first,
		active_head   = NIL_RUNTIME,
		channel       = template_tl.channel,
		transposition = template_tl.transposition,
		rate          = template_tl.rate,
	}
	sequencer.runtime_root = root_idx
}

// Advance the playhead by `dt` seconds, tick the root instance, and
// adopt any spawned Timeline instances into its active chain.
sequencer_tick :: proc(sequencer: ^Sequencer, dt: f32) {
	sequencer.beat += dt * sequencer.tempo / 60.0

	spawn_head := play_timeline(sequencer, sequencer.runtime_root, sequencer.beat)
	if spawn_head == NIL_RUNTIME do return

	root_event := runtime_get(sequencer, sequencer.runtime_root)
	root_timeline := &root_event.kind.(Timeline)

	tail := spawn_head
	for {
		event := runtime_get(sequencer, tail)
		if event.active_next == NIL_RUNTIME do break
		tail = event.active_next
	}
	runtime_get(sequencer, tail).active_next = root_timeline.active_head
	root_timeline.active_head = spawn_head
}

// The root instance has nothing pending and nothing sounding.
sequencer_finished :: proc(sequencer: ^Sequencer) -> bool {
	root := runtime_get(sequencer, sequencer.runtime_root)
	timeline := root.kind.(Timeline)
	return timeline.cursor == NIL_TEMPLATE && timeline.active_head == NIL_RUNTIME
}


// ===== Play =====

@(private)
sink_note_on :: proc(sink: ^Sink, channel, number, velocity: i32) {
	if sink.note_on != nil do sink.note_on(sink.user, channel, number, velocity)
}

@(private)
sink_note_off :: proc(sink: ^Sink, channel, number: i32) {
	if sink.note_off != nil do sink.note_off(sink.user, channel, number)
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

// Advance the runtime Timeline instance at `timeline_event_idx` to
// `local_time` (in beats, relative to that instance's own start) and
// return a chain of newly-spawned Timeline instances for the caller to
// adopt.
//
//   Cursor walks the authored children chain in the template pool.
//   Each fired event is copied into a fresh runtime instance.
//   Note-instances join this timeline's own active chain; Timeline
//   instances are returned via the spawn chain (flattens recursion).
//   On completion, runtime instances are freed back to the runtime pool.
play_timeline :: proc(
	sequencer: ^Sequencer,
	timeline_event_idx: Runtime_Index,
	local_time: f32,
) -> Runtime_Index {
	timeline_event := runtime_get(sequencer, timeline_event_idx)
	timeline := &timeline_event.kind.(Timeline)

	spawn_head := NIL_RUNTIME

	// Pass 1: walk the template cursor, alloc a runtime instance per fired event.
	for timeline.cursor != NIL_TEMPLATE {
		cursor_event := event_get(sequencer, timeline.cursor)
		if cursor_event.beat > local_time do break

		// Probabilistic skip. If the chance roll fails, advance past the
		// event without allocating anything.
		if cursor_event.chance < 100 {
			roll := i32(rand_u32(&sequencer.rng_state) % 100)
			if roll >= cursor_event.chance {
				timeline.cursor = cursor_event.next
				continue
			}
		}

		new_idx := runtime_alloc(sequencer)
		if new_idx == NIL_RUNTIME do break // pool exhausted; try again next tick
		new_event := runtime_get(sequencer, new_idx)
		new_event.beat = cursor_event.beat
		new_event.chance = cursor_event.chance
		new_event.kind = cursor_event.kind

		switch k in new_event.kind {
		case Note:
			new_event.active_next = timeline.active_head
			timeline.active_head = new_idx
			sink_note_on(
				&sequencer.sink,
				timeline.channel,
				k.number + timeline.transposition,
				k.velocity,
			)
		case Timeline:
			new_timeline := &new_event.kind.(Timeline)
			new_timeline.cursor = new_timeline.first
			new_timeline.active_head = NIL_RUNTIME
			new_timeline.transposition += timeline.transposition
			new_timeline.rate *= timeline.rate
			new_event.active_next = spawn_head
			spawn_head = new_idx
		}

		timeline.cursor = cursor_event.next
	}

	// Pass 2: tick active runtime instances, free finished ones, collect sub-spawns.
	prev_idx := NIL_RUNTIME
	current := timeline.active_head
	for current != NIL_RUNTIME {
		current_event := runtime_get(sequencer, current)
		next := current_event.active_next

		finished: bool
		switch k in current_event.kind {
		case Note:
			if current_event.beat + k.duration <= local_time {
				sink_note_off(&sequencer.sink, timeline.channel, k.number + timeline.transposition)
				finished = true
			}
		case Timeline:
			child := &current_event.kind.(Timeline)
			sub_head := play_timeline(
				sequencer,
				current,
				(local_time - current_event.beat) * child.rate,
			)
			if sub_head != NIL_RUNTIME {
				sub_tail := sub_head
				walker := sub_head
				for walker != NIL_RUNTIME {
					walker_event := runtime_get(sequencer, walker)
					walker_event.beat = walker_event.beat / child.rate + current_event.beat
					sub_tail = walker
					walker = walker_event.active_next
				}
				runtime_get(sequencer, sub_tail).active_next = spawn_head
				spawn_head = sub_head
			}
			finished = child.cursor == NIL_TEMPLATE && child.active_head == NIL_RUNTIME
		}

		if finished {
			if prev_idx == NIL_RUNTIME {
				timeline.active_head = next
			} else {
				runtime_get(sequencer, prev_idx).active_next = next
			}
			runtime_free(sequencer, current)
		} else {
			prev_idx = current
		}

		current = next
	}

	return spawn_head
}
