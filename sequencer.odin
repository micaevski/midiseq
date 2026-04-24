package main


DEFAULT_POOL_BYTES :: 32 * 1024 * 1024


// Index into the Event pool. 0 is reserved as the nil sentinel, so every
// default-zeroed field that holds an Event_Index (Timeline.first, Event.prev,
// Event.next, Event.active_next, Sequencer.root) is a valid "points to nothing".
Event_Index :: distinct u32
NIL_EVENT :: Event_Index(0)


Note :: struct {
	number:   i32, // MIDI note, 0..127
	velocity: i32, // 0..127
	duration: f32, // in beats; note-off fires at start_beat + duration
}

// A Timeline is a doubly-linked list of child Events sorted by beat,
// plus a small amount of runtime state.
//
// Authoring:
//   first - head of the sibling chain
//   channel - MIDI channel (0..15) for Notes in this Timeline
//
// Runtime:
//   cursor - next sibling Event that has yet to be started
//   active_head - head of the active chain (currently-sounding children),
//     linked via Event.active_next
Timeline :: struct {
	first:       Event_Index,
	cursor:      Event_Index,
	active_head: Event_Index,
	channel:     i32,
}

Event_Kind :: union {
	Note,
	Timeline,
}

// An Event lives in the Sequencer's pool.
//   prev/next  - sibling chain in the parent Timeline, sorted by beat.
//   active_next - active chain in the parent Timeline (unsorted, head-inserted).
Event :: struct {
	beat:        f32,
	kind:        Event_Kind,
	prev:        Event_Index,
	next:        Event_Index,
	active_next: Event_Index,
}

// The Sequencer owns the pool and the root Event. MIDI output is
// delegated to a Midi_Out (which handles ref-counted note-on/note-off
// coalescing).
Sequencer :: struct {
	tempo: f32, // beats per minute
	beat:  f32, // current playhead, in beats
	root:  Event_Index,
	pool:  Pool(Event),
	midi:  ^Midi_Out,
}


make_sequencer :: proc(pool_bytes: int = DEFAULT_POOL_BYTES) -> Sequencer {
	capacity := pool_bytes / size_of(Event)
	sequencer := Sequencer{}
	pool_init(&sequencer.pool, capacity)
	return sequencer
}

destroy_sequencer :: proc(sequencer: ^Sequencer) {
	pool_destroy(&sequencer.pool)
}

// Event-typed wrappers around the generic Pool so call sites don't cast.
event_alloc :: proc(sequencer: ^Sequencer) -> Event_Index {
	return Event_Index(pool_alloc(&sequencer.pool))
}

event_free :: proc(sequencer: ^Sequencer, index: Event_Index) {
	pool_free(&sequencer.pool, u32(index))
}

event_get :: proc(sequencer: ^Sequencer, index: Event_Index) -> ^Event {
	return pool_get(&sequencer.pool, u32(index))
}

// Insert `event` into the child list of the Timeline stored at `parent`,
// keeping the list sorted by beat. Ties go after existing events at the
// same beat (stable insertion). Returns the new event's index, or
// NIL_EVENT if the pool is full. Panics if `parent` is not a Timeline.
add_event :: proc(sequencer: ^Sequencer, parent: Event_Index, event: Event) -> Event_Index {
	new_idx := event_alloc(sequencer)
	if new_idx == NIL_EVENT do return NIL_EVENT

	new_event := event_get(sequencer, new_idx)
	new_event^ = event

	parent_event := event_get(sequencer, parent)
	timeline := &parent_event.kind.(Timeline)

	current_idx := timeline.first
	prev_idx := NIL_EVENT
	for current_idx != NIL_EVENT {
		current_event := event_get(sequencer, current_idx)
		if current_event.beat > event.beat do break
		prev_idx = current_idx
		current_idx = current_event.next
	}

	new_event.prev = prev_idx
	new_event.next = current_idx
	if prev_idx == NIL_EVENT {
		timeline.first = new_idx
	} else {
		event_get(sequencer, prev_idx).next = new_idx
	}
	if current_idx != NIL_EVENT {
		event_get(sequencer, current_idx).prev = new_idx
	}

	return new_idx
}


// ===== Sequencer driver =====

// Prepare the root Timeline for a fresh playback pass.
start_sequencer :: proc(sequencer: ^Sequencer) {
	sequencer.beat = 0
	root_event := event_get(sequencer, sequencer.root)
	timeline := &root_event.kind.(Timeline)
	timeline.cursor = timeline.first
	timeline.active_head = NIL_EVENT
}

// Advance the playhead by `dt` seconds and play whatever falls in the window.
sequencer_tick :: proc(sequencer: ^Sequencer, dt: f32) {
	sequencer.beat += dt * sequencer.tempo / 60.0
	play_timeline(sequencer, sequencer.root, sequencer.beat)
}

// The root has nothing pending and nothing sounding.
sequencer_finished :: proc(sequencer: ^Sequencer) -> bool {
	root := event_get(sequencer, sequencer.root)
	timeline := root.kind.(Timeline)
	return timeline.cursor == NIL_EVENT && timeline.active_head == NIL_EVENT
}


// ===== Play =====

// Advance the Timeline rooted at `timeline_event_idx` to `local_time`
// (in beats, relative to that Timeline's own start). Two passes:
//   1. Start any pending events whose beat has been reached.
//   2. Tick active nested Timelines recursively; unlink anything that
//      has finished.
// A Note is finished at start_beat + duration. A Timeline is finished
// when it has no pending events and nothing currently sounding.
play_timeline :: proc(sequencer: ^Sequencer, timeline_event_idx: Event_Index, local_time: f32) {
	timeline_event := event_get(sequencer, timeline_event_idx)
	timeline := &timeline_event.kind.(Timeline)

	// Pass 1: start pending events.
	for timeline.cursor != NIL_EVENT {
		cursor_event := event_get(sequencer, timeline.cursor)
		if cursor_event.beat > local_time do break

		switch k in cursor_event.kind {
		case Note:
			midi_note_on(sequencer.midi, timeline.channel, k.number, k.velocity)
		case Timeline:
			child := &cursor_event.kind.(Timeline)
			child.cursor = child.first
			child.active_head = NIL_EVENT
		}

		cursor_event.active_next = timeline.active_head
		timeline.active_head = timeline.cursor
		timeline.cursor = cursor_event.next
	}

	// Pass 2: tick active children, unlink those that have finished.
	prev_idx := NIL_EVENT
	current := timeline.active_head
	for current != NIL_EVENT {
		current_event := event_get(sequencer, current)
		next := current_event.active_next

		finished: bool
		switch k in current_event.kind {
		case Note:
			if current_event.beat + k.duration <= local_time {
				midi_note_off(sequencer.midi, timeline.channel, k.number)
				finished = true
			}
		case Timeline:
			play_timeline(sequencer, current, local_time - current_event.beat)
			child := &current_event.kind.(Timeline)
			finished = child.cursor == NIL_EVENT && child.active_head == NIL_EVENT
		}

		if finished {
			if prev_idx == NIL_EVENT {
				timeline.active_head = next
			} else {
				event_get(sequencer, prev_idx).active_next = next
			}
		} else {
			prev_idx = current
		}

		current = next
	}
}
