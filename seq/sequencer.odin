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

// Runtime_Note is the in-flight version of a fired Note. The parent
// timeline that fired it may retire before the note finishes, so the
// note carries everything note-off needs:
//
//   number             — already transposed (source.number + parent.transposition).
//   duration           — already root-time (source.duration / parent.rate).
//   parent_source_idx  — the source ref that fired this note. Used to
//                        look up the channel (and the ref's name).
Runtime_Note :: struct {
	number:            i32,
	duration:          f32,
	parent_source_idx: Source_Index,
}

// Runtime_Timeline is a live instance of a Source_Timeline.
//
//   cursor               — position in the *source* child chain we're firing from.
//                          Walks `next` links in the source pool.
//   source_idx           — the source ref event this runtime was cloned from.
//                          Used to look up the ref's channel and name.
//   transposition / rate — accumulated from ancestors at clone time.
Runtime_Timeline :: struct {
	cursor:        Source_Index,
	source_idx:    Source_Index,
	transposition: i32,
	rate:          f32,
}

Runtime_Kind :: union {
	Runtime_Note,
	Runtime_Timeline,
}

// Runtime_Event lives in the runtime pool and is created during playback.
// `beat` is in root-time; `active_next` links into the sequencer's
// single flat active chain.
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
// `source_root` is the authored root. `active_head`/`active_tail` form
// the single flat chain of all live runtime events (notes and
// timelines), built from a fresh clone of the root every time
// start_sequencer is called.
Sequencer :: struct {
	tempo:        f32,
	beat:         f32,
	source_root:  Source_Index,
	active_head:  Runtime_Index,
	active_tail:  Runtime_Index,
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

// Reset the runtime pool, allocate a fresh root timeline instance, and
// install it as the only entry on the active chain. Safe to call
// repeatedly (Stop -> Start).
start_sequencer :: proc(sequencer: ^Sequencer) {
	sequencer.beat = 0

	// Wipe the runtime pool — no need to walk-and-free individual events.
	sequencer.runtime_pool.count = 1
	sequencer.runtime_pool.free_head = 0

	source := source_get(sequencer, sequencer.source_root)
	source_timeline := source.kind.(Source_Timeline)

	root_idx := runtime_alloc(sequencer)
	root_event := runtime_get(sequencer, root_idx)
	root_event.beat = 0
	root_event.kind = Runtime_Timeline {
		cursor        = source_timeline.first,
		source_idx    = sequencer.source_root,
		transposition = source_timeline.transposition,
		rate          = source_timeline.rate,
	}
	root_event.active_next = NIL_RUNTIME

	sequencer.active_head = root_idx
	sequencer.active_tail = root_idx
}

// Advance the playhead by `dt` seconds and drive playback.
//
// One single-pass walk over the active chain:
//
//   - Runtime_Note: retire (note-off + free) when its end time has
//     been reached.
//   - Runtime_Timeline: tick its cursor via `play_timeline`, append
//     the returned chain (already in root-time) onto `active_tail`.
//     The walk re-reads `active_next` after the append, so newly
//     spawned events are visited later in this same tick. The
//     timeline retires when its cursor empties; its in-flight notes
//     outlive it and retire on their own when their duration runs out.
sequencer_tick :: proc(sequencer: ^Sequencer, dt: f32) {
	sequencer.beat += dt * sequencer.tempo / 60.0

	prev := NIL_RUNTIME
	cur := sequencer.active_head
	for cur != NIL_RUNTIME {
		event := runtime_get(sequencer, cur)

		finished: bool
		switch k in event.kind {
		case Runtime_Note:
			if event.beat + k.duration <= sequencer.beat {
				sink_note_off(
					&sequencer.sink,
					channel_of(sequencer, k.parent_source_idx),
					k.number,
				)
				finished = true
			}
		case Runtime_Timeline:
			sub_local := (sequencer.beat - event.beat) * k.rate
			spawn_head, spawn_tail := play_timeline(sequencer, cur, sub_local)
			if spawn_head != NIL_RUNTIME {
				// Append onto the active chain's tail. Re-reading `next`
				// below picks up these spawns when `cur` was the old tail.
				if sequencer.active_tail == NIL_RUNTIME {
					sequencer.active_head = spawn_head
				} else {
					runtime_get(sequencer, sequencer.active_tail).active_next = spawn_head
				}
				sequencer.active_tail = spawn_tail
			}
			// Re-read after potential append (`event` still valid; the
			// runtime pool is a fixed slice).
			finished = event.kind.(Runtime_Timeline).cursor == NIL_SOURCE
		}

		next := event.active_next

		if finished {
			if prev == NIL_RUNTIME {
				sequencer.active_head = next
			} else {
				runtime_get(sequencer, prev).active_next = next
			}
			if cur == sequencer.active_tail {
				sequencer.active_tail = prev
			}
			runtime_free(sequencer, cur)
		} else {
			prev = cur
		}
		cur = next
	}
}


// Nothing is in flight.
sequencer_finished :: proc(sequencer: ^Sequencer) -> bool {
	return sequencer.active_head == NIL_RUNTIME
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

// Look up the channel authored on a Source_Timeline. Used at note-on
// (via the timeline's own `source_idx`) and note-off (via the note's
// `parent_source_idx`).
@(private)
channel_of :: proc(sequencer: ^Sequencer, src: Source_Index) -> i32 {
	return source_get(sequencer, src).kind.(Source_Timeline).channel
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

// Walk one runtime timeline's source cursor up to `local_time` (in
// beats, relative to that instance's own start). For each fired source
// event, allocate a runtime event (firing note-on for notes) and
// append it to a local spawn chain in firing order. Beats on spawned
// events are translated into root-time using the timeline's own start
// beat and accumulated rate, so the caller can splice the chain
// straight onto the sequencer's active list.
//
// Returns the (head, tail) of the spawn chain so the caller can splice
// in O(1) without re-walking.
play_timeline :: proc(
	sequencer: ^Sequencer,
	timeline_event_idx: Runtime_Index,
	local_time: f32,
) -> (
	spawn_head: Runtime_Index,
	spawn_tail: Runtime_Index,
) {
	timeline_event := runtime_get(sequencer, timeline_event_idx)
	timeline := &timeline_event.kind.(Runtime_Timeline)

	spawn_head = NIL_RUNTIME
	spawn_tail = NIL_RUNTIME

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
		// Translate the source-domain beat into root-time. For the root
		// timeline (rate=1, start=0) this is identity.
		runtime_event.beat = cursor_event.beat / timeline.rate + timeline_event.beat
		runtime_event.active_next = NIL_RUNTIME

		switch k in cursor_event.kind {
		case Note:
			runtime_event.kind = Runtime_Note {
				number            = k.number + timeline.transposition,
				duration          = k.duration / timeline.rate,
				parent_source_idx = timeline.source_idx,
			}
			sink_note_on(
				&sequencer.sink,
				channel_of(sequencer, timeline.source_idx),
				k.number + timeline.transposition,
				k.velocity,
			)
		case Source_Timeline:
			runtime_event.kind = Runtime_Timeline {
				cursor        = k.first,
				source_idx    = timeline.cursor,
				transposition = k.transposition + timeline.transposition,
				rate          = k.rate * timeline.rate,
			}
		}

		// Append (head→tail) so spawn_head stays in firing order.
		if spawn_tail == NIL_RUNTIME {
			spawn_head = new_idx
		} else {
			runtime_get(sequencer, spawn_tail).active_next = new_idx
		}
		spawn_tail = new_idx

		timeline.cursor = cursor_event.next
	}

	return
}
