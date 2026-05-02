package tests

import "../source/seq"
import "core:testing"


@(private = "file")
Captured_Note :: struct {
	channel:  i32,
	number:   i32,
	velocity: i32,
	beat:     f32,
}

@(private = "file")
Test_Sink :: struct {
	notes: [dynamic]Captured_Note,
}

@(private = "file")
test_note_on :: proc(user: rawptr, channel, number, velocity: i32, beat: f32) {
	sink := cast(^seq.Sink)user
	ts := cast(^Test_Sink)sink.user
	append(&ts.notes, Captured_Note{channel, number, velocity, beat})
}

@(private = "file")
test_note_off :: proc(user: rawptr, channel, number: i32, beat: f32) {}

@(private = "file")
test_cc :: proc(user: rawptr, channel, number, value: i32, beat: f32) {}

@(private = "file")
make_test_sink :: proc(ts: ^Test_Sink) -> seq.Sink {
	return seq.Sink{user = ts, note_on = test_note_on, note_off = test_note_off, cc = test_cc}
}


// An orphan loop spawned with `!` from a non-root host bubbles up its
// runtime parent to the root and keeps firing on its own. Removing the
// `ECHO!` invocation from the host's body — without touching ECHO's
// own definition — should retire the orphan on the next adapt.
@(test)
test_orphan_retires_when_invocation_removed :: proc(t: ^testing.T) {
	src1 := `ECHO:
C4 1 vel=80
ECHO! 2

HOST:
ECHO!
C-1 100

HOST
`
	src2 := `ECHO:
C4 1 vel=80
ECHO! 2

HOST:
C-1 100

HOST
`
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)

	root1, ok1 := seq.parse_source(&parser, src1)
	testing.expect(t, ok1)

	ts: Test_Sink
	defer delete(ts.notes)
	sink := make_test_sink(&ts)
	sequencer := seq.make_sequencer(sink)
	defer seq.destroy_sequencer(sequencer)

	seq.adapt_to_source(sequencer, &parser, root1)
	seq.start(sequencer)

	// Tick across several beats; ECHO should fire repeatedly.
	for beat in 0 ..< 6 {
		seq.tick(sequencer, f32(beat))
	}
	notes_before_reparse := len(ts.notes)
	testing.expect(t, notes_before_reparse > 1, "ECHO should have fired multiple times before the reparse")

	// Reparse with HOST's `ECHO!` invocation removed; ECHO definition
	// itself is unchanged.
	root2, ok2 := seq.parse_source(&parser, src2)
	testing.expect(t, ok2)
	seq.adapt_to_source(sequencer, &parser, root2)

	// Snapshot count immediately after adapt and tick further. The
	// orphan should not produce any new notes.
	notes_at_adapt := len(ts.notes)
	for beat in 6 ..< 12 {
		seq.tick(sequencer, f32(beat))
	}
	notes_after_more_ticks := len(ts.notes)

	testing.expect_value(t, notes_after_more_ticks, notes_at_adapt)
}
