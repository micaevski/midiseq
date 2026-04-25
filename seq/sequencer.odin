package seq

import "core:mem"


DEFAULT_POOL_BYTES :: 1_000_000 * size_of(Source_Event)
NAMES_ARENA_BYTES :: 16 * 1024


// Distinct index types for the two pools. Index 0 is the nil sentinel for
// both, so default-zeroed fields safely mean "points to nothing".
Source_Index :: distinct u32
Runtime_Index :: distinct u32
NIL_SOURCE :: Source_Index(0)
NIL_RUNTIME :: Runtime_Index(0)


// Shared between source and runtime — a Note carries the same data on
// both sides.
Note :: struct {
	number:   i32, // MIDI note, 0..127
	velocity: i32, // 0..127
	duration: f32, // in beats; note-off fires at start_beat + duration
}


// ===== Source pool =====

// Source_Timeline is the authored shape of a timeline (top-level def or
// reference). `first` heads its child sibling chain.
Source_Timeline :: struct {
	first:         Source_Index,
	channel:       i32,
	transposition: i32, // semitones
	rate:          f32, // time-scale multiplier
}

Source_Kind :: union {
	Note,
	Source_Timeline,
}

// Source_Event lives in the source pool and is written by the parser.
// `prev`/`next` form the sibling chain inside a parent timeline's
// children list.
Source_Event :: struct {
	beat:   f32,
	chance: i32, // 0..100; probability of firing. 100 = always.
	kind:   Source_Kind,
	prev:   Source_Index,
	next:   Source_Index,
}


// ===== Runtime pool =====

// Runtime_Timeline is a live instance of a Source_Timeline.
//
//   cursor      — position in the *source* child chain we're firing from.
//                 Walks `next` links in the source pool; advances during
//                 play and stops at NIL_SOURCE.
//   active_head — head of currently-sounding child runtime instances.
//   source_idx  — the source ref event this runtime was cloned from.
//                 Stable for the life of the instance — used to look up
//                 the channel (`source_get(s, source_idx).kind`) and the
//                 ref's name in `Sequencer.names`.
//   transposition / rate — already accumulated from parent at clone time.
Runtime_Timeline :: struct {
	cursor:        Source_Index,
	active_head:   Runtime_Index,
	source_idx:    Source_Index,
	transposition: i32,
	rate:          f32,
}

Runtime_Kind :: union {
	Note,
	Runtime_Timeline,
}

// Runtime_Event lives in the runtime pool and is created during playback.
// `active_next` links into its parent timeline's active chain.
Runtime_Event :: struct {
	beat:        f32,
	kind:        Runtime_Kind,
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


// `lookup` maps a source-pool index to a human-readable name from the
// DSL: top-level definitions get their own name, references get the
// name of their target (so `BASS(0)` is labeled "BASS"). Strings are
// cloned into `arena` during parse so they outlive the parser's own
// arena.
Names :: struct {
	lookup:    map[Source_Index]string,
	arena:     mem.Arena,
	arena_buf: []byte,
}


// The Sequencer holds two pools:
//   source_pool  - authored source events, written by the parser.
//   runtime_pool - transient instances created during playback.
// `source_root` is the authored root. `runtime_root` is a fresh runtime
// clone of it, re-created every time start_sequencer is called.
Sequencer :: struct {
	tempo:        f32,
	beat:         f32,
	source_root:  Source_Index,
	runtime_root: Runtime_Index,
	source_pool:  Pool(Source_Event),
	runtime_pool: Pool(Runtime_Event),
	sink:         Sink,
	rng_state:    u32, // xorshift32; set via `SEED = N` in source
	names:        Names,
}


make_sequencer :: proc(pool_bytes: int = DEFAULT_POOL_BYTES) -> Sequencer {
	source_capacity := pool_bytes / size_of(Source_Event)
	runtime_capacity := pool_bytes / size_of(Runtime_Event)
	sequencer := Sequencer{}
	pool_init(&sequencer.source_pool, source_capacity)
	pool_init(&sequencer.runtime_pool, runtime_capacity)

	sequencer.names.arena_buf = make([]byte, NAMES_ARENA_BYTES)
	mem.arena_init(&sequencer.names.arena, sequencer.names.arena_buf)
	sequencer.names.lookup = make(map[Source_Index]string, 32)
	return sequencer
}

destroy_sequencer :: proc(sequencer: ^Sequencer) {
	pool_destroy(&sequencer.source_pool)
	pool_destroy(&sequencer.runtime_pool)
	delete(sequencer.names.lookup)
	delete(sequencer.names.arena_buf)
}


// Source-pool wrappers (parser side).
source_alloc :: proc(sequencer: ^Sequencer) -> Source_Index {
	return Source_Index(pool_alloc(&sequencer.source_pool))
}

source_free :: proc(sequencer: ^Sequencer, index: Source_Index) {
	pool_free(&sequencer.source_pool, u32(index))
}

source_get :: proc(sequencer: ^Sequencer, index: Source_Index) -> ^Source_Event {
	return pool_get(&sequencer.source_pool, u32(index))
}

// Runtime-pool wrappers (playback side).
runtime_alloc :: proc(sequencer: ^Sequencer) -> Runtime_Index {
	return Runtime_Index(pool_alloc(&sequencer.runtime_pool))
}

runtime_free :: proc(sequencer: ^Sequencer, index: Runtime_Index) {
	pool_free(&sequencer.runtime_pool, u32(index))
}

runtime_get :: proc(sequencer: ^Sequencer, index: Runtime_Index) -> ^Runtime_Event {
	return pool_get(&sequencer.runtime_pool, u32(index))
}


// Insert `event` into the child list of the Source_Timeline stored at
// `parent`, keeping the list sorted by beat. Ties go after existing
// events at the same beat (stable insertion). Returns the new event's
// index, or NIL_SOURCE if the pool is full. Panics if `parent` is not
// a Source_Timeline.
add_source_event :: proc(
	sequencer: ^Sequencer,
	parent: Source_Index,
	event: Source_Event,
) -> Source_Index {
	new_idx := source_alloc(sequencer)
	if new_idx == NIL_SOURCE do return NIL_SOURCE

	new_event := source_get(sequencer, new_idx)
	new_event^ = event

	parent_event := source_get(sequencer, parent)
	timeline := &parent_event.kind.(Source_Timeline)

	current_idx := timeline.first
	prev_idx := NIL_SOURCE
	for current_idx != NIL_SOURCE {
		current_event := source_get(sequencer, current_idx)
		if current_event.beat > event.beat do break
		prev_idx = current_idx
		current_idx = current_event.next
	}

	new_event.prev = prev_idx
	new_event.next = current_idx
	if prev_idx == NIL_SOURCE {
		timeline.first = new_idx
	} else {
		source_get(sequencer, prev_idx).next = new_idx
	}
	if current_idx != NIL_SOURCE {
		source_get(sequencer, current_idx).prev = new_idx
	}

	return new_idx
}


// ===== Sequencer driver =====

// Reset the runtime pool and allocate a fresh root instance cloned from
// the authored root source. Safe to call repeatedly (Stop -> Start).
start_sequencer :: proc(sequencer: ^Sequencer) {
	sequencer.beat = 0

	// Wipe the runtime pool — no need to walk-and-free individual events.
	sequencer.runtime_pool.count = 1
	sequencer.runtime_pool.free_head = 0

	// Clone the authored root as a fresh runtime instance.
	source := source_get(sequencer, sequencer.source_root)
	source_timeline := source.kind.(Source_Timeline)

	root_idx := runtime_alloc(sequencer)
	root_event := runtime_get(sequencer, root_idx)
	root_event.beat = 0
	root_event.kind = Runtime_Timeline {
		cursor        = source_timeline.first,
		active_head   = NIL_RUNTIME,
		source_idx    = sequencer.source_root,
		transposition = source_timeline.transposition,
		rate          = source_timeline.rate,
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
	root_timeline := &root_event.kind.(Runtime_Timeline)

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
	timeline := root.kind.(Runtime_Timeline)
	return timeline.cursor == NIL_SOURCE && timeline.active_head == NIL_RUNTIME
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

// Look up the channel a runtime timeline should emit on by reading the
// authored channel off its source ref. Channel doesn't accumulate from
// parent (unlike transposition/rate), so it lives only on the source
// side.
@(private)
runtime_channel :: proc(sequencer: ^Sequencer, t: Runtime_Timeline) -> i32 {
	return source_get(sequencer, t.source_idx).kind.(Source_Timeline).channel
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
//   Cursor walks the authored children chain in the source pool.
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
	timeline := &timeline_event.kind.(Runtime_Timeline)

	spawn_head := NIL_RUNTIME

	// Process events in the source and add them to the runtime active chain
	for timeline.cursor != NIL_SOURCE {
		cursor_event := source_get(sequencer, timeline.cursor)
		if cursor_event.beat > local_time do break

		// Evaluate chance.
		if cursor_event.chance < 100 {
			roll := i32(rand_u32(&sequencer.rng_state) % 100)
			if roll >= cursor_event.chance {
				timeline.cursor = cursor_event.next
				continue
			}
		}

		new_idx := runtime_alloc(sequencer)
		if new_idx == NIL_RUNTIME do break // pool exhausted; try again next tick
		runtime_event := runtime_get(sequencer, new_idx)
		runtime_event.beat = cursor_event.beat

		switch k in cursor_event.kind {
		case Note:
			runtime_event.kind = k
			runtime_event.active_next = timeline.active_head
			timeline.active_head = new_idx
			// fire notes
			sink_note_on(
				&sequencer.sink,
				runtime_channel(sequencer, timeline^),
				k.number + timeline.transposition,
				k.velocity,
			)
		case Source_Timeline:
			// Build a fresh runtime instance, accumulating
			// transposition/rate from the parent and remembering the
			// source ref we cloned from.
			runtime_event.kind = Runtime_Timeline {
				cursor        = k.first,
				active_head   = NIL_RUNTIME,
				source_idx    = timeline.cursor,
				transposition = k.transposition + timeline.transposition,
				rate          = k.rate * timeline.rate,
			}
			// runtime timelines get added to the spawn list
			runtime_event.active_next = spawn_head
			spawn_head = new_idx
		}

		timeline.cursor = cursor_event.next
	}

	// Recursively walk the active chain and retire any finished events, while bubbling up timelines.
	prev_idx := NIL_RUNTIME
	current := timeline.active_head
	for current != NIL_RUNTIME {
		current_event := runtime_get(sequencer, current)
		next := current_event.active_next

		finished: bool
		switch k in current_event.kind {
		case Note:
			if current_event.beat + k.duration <= local_time {
				sink_note_off(
					&sequencer.sink,
					runtime_channel(sequencer, timeline^),
					k.number + timeline.transposition,
				)
				finished = true
			}
		case Runtime_Timeline:
			child := &current_event.kind.(Runtime_Timeline)
			// recursively play child timelines, accumulating spawns
			sub_head := play_timeline(
				sequencer,
				current,
				(local_time - current_event.beat) * child.rate,
			)
			// if there are child timelines spawned, append them to the spawn list.
			if sub_head != NIL_RUNTIME {
				sub_tail := sub_head
				walker := sub_head
				// Update the beat value to account for offset from the parent timeline and the rate scaling.
				for walker != NIL_RUNTIME {
					walker_event := runtime_get(sequencer, walker)
					walker_event.beat = walker_event.beat / child.rate + current_event.beat
					sub_tail = walker
					walker = walker_event.active_next
				}
				runtime_get(sequencer, sub_tail).active_next = spawn_head
				spawn_head = sub_head
			}
			finished = child.cursor == NIL_SOURCE && child.active_head == NIL_RUNTIME
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
