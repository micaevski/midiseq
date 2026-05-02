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
make_test_sink :: proc(ts: ^Test_Sink) -> seq.Sink {
	return seq.Sink{user = ts, note_on = test_note_on, note_off = test_note_off}
}


// Parse `src`, hand the parsed source to a fresh sequencer, start it,
// tick once at beat 0, return the captured notes. Caller frees the
// dynamic array via `defer delete(ts.notes)`.
//
// Note for callers: the existing seq design auto-retires Runtime_Timeline
// children when their parent's source cursor reaches NIL_SOURCE. In real
// songs the user keeps parents alive via self-recursion (`SONG! 5`); in
// these tests we add a far-future `C-1 100` filler event to keep the
// fork's parent timeline alive long enough for the synthetic timeline
// (spawned by the fork) to play its branch.
@(private = "file")
run_one_tick :: proc(t: ^testing.T, src: string) -> (ts: Test_Sink, parsed: bool) {
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)

	root, p_ok := seq.parse_source(&parser, src)
	if !p_ok do return Test_Sink{}, false

	sink := make_test_sink(&ts)
	sequencer := seq.make_sequencer(sink)
	defer seq.destroy_sequencer(sequencer)

	seq.adapt_to_source(sequencer, &parser, root)
	seq.start(sequencer)
	seq.tick(sequencer, 0)
	return ts, true
}


// =============================================================================
// Runtime behaviour: predicate selects the right branch, fork's parent
// snapshot drives the predicate.
// =============================================================================


@(test)
test_fork_then_branch_fires :: proc(t: ^testing.T) {
	src := `INNER:
if trans > 5
C4 1
else
C5 1
end
C-1 100

SONG:
INNER trans=10
C-1 100

SONG
`
	ts, ok := run_one_tick(t, src)
	defer delete(ts.notes)
	testing.expect(t, ok, "parse should succeed")
	testing.expect_value(t, len(ts.notes), 1)
	// trans=10 > 5 → then → C4(60) + 10 = 70.
	testing.expect_value(t, ts.notes[0].number, i32(70))
}


@(test)
test_fork_else_branch_fires :: proc(t: ^testing.T) {
	src := `INNER:
if trans > 5
C4 1
else
C5 1
end
C-1 100

SONG:
INNER trans=3
C-1 100

SONG
`
	ts, ok := run_one_tick(t, src)
	defer delete(ts.notes)
	testing.expect(t, ok)
	testing.expect_value(t, len(ts.notes), 1)
	// trans=3 not > 5 → else → C5(72) + 3 = 75.
	testing.expect_value(t, ts.notes[0].number, i32(75))
}


@(test)
test_fork_no_else_branch_then_fires :: proc(t: ^testing.T) {
	src := `INNER:
if trans >= 5
C4 1
end
C-1 100

SONG:
INNER trans=5
C-1 100

SONG
`
	ts, ok := run_one_tick(t, src)
	defer delete(ts.notes)
	testing.expect(t, ok)
	testing.expect_value(t, len(ts.notes), 1)
	testing.expect_value(t, ts.notes[0].number, i32(65))
}


@(test)
test_fork_no_else_branch_skipped :: proc(t: ^testing.T) {
	src := `INNER:
if trans > 5
C4 1
end
C-1 100

SONG:
INNER trans=2
C-1 100

SONG
`
	ts, ok := run_one_tick(t, src)
	defer delete(ts.notes)
	testing.expect(t, ok)
	// Predicate false, no else branch → fork retires without spawning.
	testing.expect_value(t, len(ts.notes), 0)
}


@(test)
test_fork_rate_predicate :: proc(t: ^testing.T) {
	src := `INNER:
if rate >= 2
C4 1
else
C5 1
end
C-1 100

SONG:
INNER rate=2
C-1 100

SONG
`
	ts, ok := run_one_tick(t, src)
	defer delete(ts.notes)
	testing.expect(t, ok)
	testing.expect_value(t, len(ts.notes), 1)
	// rate=2 >= 2 → then → C4 with no transposition = 60.
	testing.expect_value(t, ts.notes[0].number, i32(60))
}


@(test)
test_fork_op_lt :: proc(t: ^testing.T) {
	src := `INNER:
if trans < 0
C4 1
else
C5 1
end
C-1 100

SONG:
INNER trans=-3
C-1 100

SONG
`
	ts, ok := run_one_tick(t, src)
	defer delete(ts.notes)
	testing.expect(t, ok)
	testing.expect_value(t, len(ts.notes), 1)
	// -3 < 0 → then → 60 + (-3) = 57.
	testing.expect_value(t, ts.notes[0].number, i32(57))
}


@(test)
test_fork_trans_degrees_predicate :: proc(t: ^testing.T) {
	// `if trans < 5d` reads the degrees field, not semitones. The
	// parent INNER bumps degrees via `trans=2d`, leaving semitones at 0;
	// without the `d` suffix the predicate would read semitones (0) and
	// always take the then branch.
	src := `INNER:
if trans < 5d
C4 1
else
C5 1
end
C-1 100

SONG:
INNER trans=2d scale=CPm
C-1 100

SONG
`
	ts, ok := run_one_tick(t, src)
	defer delete(ts.notes)
	testing.expect(t, ok)
	testing.expect_value(t, len(ts.notes), 1)
	// degrees=2 < 5 → then branch → C4 with degrees=2 in CPm.
	// CPm is C minor pentatonic (offsets 0, 3, 5, 7, 10). C4=60, +2 deg → +5 semitones → 65.
	testing.expect_value(t, ts.notes[0].number, i32(65))
}


@(test)
test_fork_d_suffix_rejected_on_rate :: proc(t: ^testing.T) {
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)
	src := `SONG:
if rate < 2d
C4 1
end

SONG
`
	_, ok := seq.parse_source(&parser, src)
	testing.expect(t, !ok, "'d' suffix should fail on non-trans field")
}


@(test)
test_fork_op_eq :: proc(t: ^testing.T) {
	src := `INNER:
if trans == 7
C4 1
else
C5 1
end
C-1 100

SONG:
INNER trans=7
C-1 100

SONG
`
	ts, ok := run_one_tick(t, src)
	defer delete(ts.notes)
	testing.expect(t, ok)
	testing.expect_value(t, len(ts.notes), 1)
	testing.expect_value(t, ts.notes[0].number, i32(67))
}


@(test)
test_fork_op_neq :: proc(t: ^testing.T) {
	src := `INNER:
if trans != 0
C4 1
else
C5 1
end
C-1 100

SONG:
INNER trans=4
C-1 100

SONG
`
	ts, ok := run_one_tick(t, src)
	defer delete(ts.notes)
	testing.expect(t, ok)
	testing.expect_value(t, len(ts.notes), 1)
	// 4 != 0 → then → 60 + 4 = 64.
	testing.expect_value(t, ts.notes[0].number, i32(64))
}


@(test)
test_fork_op_leq_boundary :: proc(t: ^testing.T) {
	src := `INNER:
if trans <= 5
C4 1
else
C5 1
end
C-1 100

SONG:
INNER trans=5
C-1 100

SONG
`
	ts, ok := run_one_tick(t, src)
	defer delete(ts.notes)
	testing.expect(t, ok)
	testing.expect_value(t, len(ts.notes), 1)
	// 5 <= 5 → then → 65.
	testing.expect_value(t, ts.notes[0].number, i32(65))
}


@(test)
test_fork_nested :: proc(t: ^testing.T) {
	// Outer trans=5 > 0 → outer-then. Inner: parent rate=3 >= 2 → inner-then → C4.
	// trans=5 propagates to the synthetic timeline that fires C4, so emit is 65.
	// The `C-1 50` filler inside the outer-then branch keeps synthetic_outer's
	// cursor alive past the inner fork spawn, so synthetic_inner isn't auto-retired
	// by the same parent_finished propagation that requires fillers elsewhere.
	src := `INNER:
if trans > 0
if rate >= 2
C4 1
else
C5 1
end
C-1 50
else
C6 1
end
C-1 100

SONG:
INNER trans=5 rate=3
C-1 100

SONG
`
	ts, ok := run_one_tick(t, src)
	defer delete(ts.notes)
	testing.expect(t, ok)
	testing.expect_value(t, len(ts.notes), 1)
	testing.expect_value(t, ts.notes[0].number, i32(65))
}


@(test)
test_macro_first_invoked_inside_else :: proc(t: ^testing.T) {
	// Regression: parse_macro_invocation didn't save/restore the parser's
	// sub_chain pointers around its body parse. A macro invoked for the
	// first time inside an else branch (or any sub-chain context) had its
	// body events redirected into the enclosing sub-chain, leaving the
	// macro instance empty — so the runtime spawn produced no notes.
	src := `LEAF():
C5 1

OUTER():
if trans < 0
C4 1
else
LEAF() trans=12
end
C-1 100

SONG:
OUTER()
C-1 100

SONG
`
	ts, ok := run_one_tick(t, src)
	defer delete(ts.notes)
	testing.expect(t, ok, "parse should succeed")
	testing.expect_value(t, len(ts.notes), 1)
	// trans=0 not < 0 → else → LEAF() trans=12 → C5(72)+12 = 84.
	// With the bug, LEAF's body was redirected into OUTER's else
	// sub-chain, so OUTER itself fired C5 at trans=0 → 72.
	testing.expect_value(t, ts.notes[0].number, i32(84))
}


// =============================================================================
// Parser-level error cases.
// =============================================================================


@(test)
test_fork_unknown_field_fails :: proc(t: ^testing.T) {
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)
	src := `SONG:
if foo > 5
C4 1
end

SONG
`
	_, ok := seq.parse_source(&parser, src)
	testing.expect(t, !ok, "unknown predicate field should fail")
}


@(test)
test_fork_implicit_end_at_blank_line :: proc(t: ^testing.T) {
	// A blank line implicitly terminates an open if-block (and
	// cascades through nested ones). The blank line itself still
	// resets the outer parser to root scope, so the `SONG` ref below
	// lands at root, not inside the fork.
	src := `SONG:
if trans < 0
C4 1
else
C5 1

SONG
`
	ts, ok := run_one_tick(t, src)
	defer delete(ts.notes)
	testing.expect(t, ok, "implicit end at blank line should parse")
	testing.expect_value(t, len(ts.notes), 1)
	// trans=0 not < 0 → else → C5 = 72.
	testing.expect_value(t, ts.notes[0].number, i32(72))
}


@(test)
test_fork_implicit_end_at_macro_body_eof :: proc(t: ^testing.T) {
	// A macro body's text is captured up to the next blank line or EOF;
	// when the body ends inside an open if-block, EOF acts as implicit end.
	src := `M():
if trans < 0
C4 1
else
C5 1

SONG:
M()
C-1 100

SONG
`
	ts, ok := run_one_tick(t, src)
	defer delete(ts.notes)
	testing.expect(t, ok, "implicit end at macro body EOF should parse")
	testing.expect_value(t, len(ts.notes), 1)
	testing.expect_value(t, ts.notes[0].number, i32(72))
}


@(test)
test_fork_implicit_end_nested :: proc(t: ^testing.T) {
	// Two open if-blocks both implicit-end at the same blank line.
	src := `SONG:
if trans < 1
if trans < 0
C4 1
else
C5 1

SONG
`
	ts, ok := run_one_tick(t, src)
	defer delete(ts.notes)
	testing.expect(t, ok, "implicit end should cascade through nested ifs")
	testing.expect_value(t, len(ts.notes), 1)
	// Outer trans=0 < 1 → outer-then. Inner trans=0 not < 0 → inner-else → C5 = 72.
	testing.expect_value(t, ts.notes[0].number, i32(72))
}


@(test)
test_fork_definition_inside_block_still_fails :: proc(t: ^testing.T) {
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)
	// Without a blank line, an upcoming definition is still a parse
	// error — the user must close the block (explicit `end` or a blank
	// line) before starting a new definition.
	src := `INNER:
if trans < 0
C4 1
SONG:
INNER

SONG
`
	_, ok := seq.parse_source(&parser, src)
	testing.expect(t, !ok, "header without blank-line separator should fail")
}


@(test)
test_fork_else_outside_fails :: proc(t: ^testing.T) {
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)
	src := `SONG:
else
C4 1

SONG
`
	_, ok := seq.parse_source(&parser, src)
	testing.expect(t, !ok)
}


@(test)
test_fork_end_outside_fails :: proc(t: ^testing.T) {
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)
	src := `SONG:
end

SONG
`
	_, ok := seq.parse_source(&parser, src)
	testing.expect(t, !ok)
}


@(test)
test_fork_if_as_label_fails :: proc(t: ^testing.T) {
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)
	src := `if:
C4 1
`
	_, ok := seq.parse_source(&parser, src)
	testing.expect(t, !ok, "'if' as label should be rejected")
}


@(test)
test_fork_unknown_op_fails :: proc(t: ^testing.T) {
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)
	src := `SONG:
if trans ~ 5
C4 1
end

SONG
`
	_, ok := seq.parse_source(&parser, src)
	testing.expect(t, !ok, "unknown operator should fail")
}
