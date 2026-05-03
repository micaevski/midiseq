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
note_on :: proc(user: rawptr, channel, number, velocity: i32, beat: f32) {
	sink := cast(^seq.Sink)user
	ts := cast(^Test_Sink)sink.user
	append(&ts.notes, Captured_Note{channel, number, velocity, beat})
}

@(private = "file")
note_off :: proc(user: rawptr, channel, number: i32, beat: f32) {}

@(private = "file")
cc :: proc(user: rawptr, channel, number, value: i32, beat: f32) {}

@(private = "file")
make_sink :: proc(ts: ^Test_Sink) -> seq.Sink {
	return seq.Sink{user = ts, note_on = note_on, note_off = note_off, cc = cc}
}


@(private = "file")
run_one_tick :: proc(t: ^testing.T, src: string) -> (ts: Test_Sink, parsed: bool) {
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)

	root, p_ok := seq.parse_source(&parser, src)
	if !p_ok do return Test_Sink{}, false

	sink := make_sink(&ts)
	sequencer := seq.make_sequencer(sink)
	defer seq.destroy_sequencer(sequencer)

	seq.adapt_to_source(sequencer, &parser, root)
	seq.start(sequencer)
	seq.tick(sequencer, 0)
	return ts, true
}


// Predicate-field coverage: vel and mod1..mod4 across the op set.
// trans/rate are exercised in fork_test.odin.


@(test)
test_predicate_velocity_then :: proc(t: ^testing.T) {
	src := `INNER:
if vel > 50
C4 1
else
C5 1
end
C-1 100

SONG:
INNER vel=80
C-1 100

SONG
`
	ts, ok := run_one_tick(t, src)
	defer delete(ts.notes)
	testing.expect(t, ok)
	testing.expect_value(t, len(ts.notes), 1)
	testing.expect_value(t, ts.notes[0].number, i32(60))
}


@(test)
test_predicate_velocity_else :: proc(t: ^testing.T) {
	src := `INNER:
if vel > 50
C4 1
else
C5 1
end
C-1 100

SONG:
INNER vel=20
C-1 100

SONG
`
	ts, ok := run_one_tick(t, src)
	defer delete(ts.notes)
	testing.expect(t, ok)
	testing.expect_value(t, len(ts.notes), 1)
	testing.expect_value(t, ts.notes[0].number, i32(72))
}


@(test)
test_predicate_mod1_geq :: proc(t: ^testing.T) {
	src := `INNER:
if mod1 >= 10
C4 1
else
C5 1
end
C-1 100

SONG:
INNER mod1=20
C-1 100

SONG
`
	ts, ok := run_one_tick(t, src)
	defer delete(ts.notes)
	testing.expect(t, ok)
	testing.expect_value(t, len(ts.notes), 1)
	testing.expect_value(t, ts.notes[0].number, i32(60))
}


@(test)
test_predicate_mod2_eq_else :: proc(t: ^testing.T) {
	src := `INNER:
if mod2 == 7
C4 1
else
C5 1
end
C-1 100

SONG:
INNER mod2=3
C-1 100

SONG
`
	ts, ok := run_one_tick(t, src)
	defer delete(ts.notes)
	testing.expect(t, ok)
	testing.expect_value(t, len(ts.notes), 1)
	testing.expect_value(t, ts.notes[0].number, i32(72))
}


@(test)
test_predicate_mod3_negative :: proc(t: ^testing.T) {
	src := `INNER:
if mod3 < 0
C4 1
else
C5 1
end
C-1 100

SONG:
INNER mod3=-5
C-1 100

SONG
`
	ts, ok := run_one_tick(t, src)
	defer delete(ts.notes)
	testing.expect(t, ok)
	testing.expect_value(t, len(ts.notes), 1)
	testing.expect_value(t, ts.notes[0].number, i32(60))
}


@(test)
test_predicate_mod4_default_zero :: proc(t: ^testing.T) {
	src := `INNER:
if mod4 != 0
C4 1
else
C5 1
end
C-1 100

SONG:
INNER
C-1 100

SONG
`
	ts, ok := run_one_tick(t, src)
	defer delete(ts.notes)
	testing.expect(t, ok)
	testing.expect_value(t, len(ts.notes), 1)
	testing.expect_value(t, ts.notes[0].number, i32(72))
}


@(test)
test_predicate_cross_field_mod1_lt_mod2 :: proc(t: ^testing.T) {
	src := `INNER:
if mod1 < mod2
C4 1
else
C5 1
end
C-1 100

SONG:
INNER mod1=3 mod2=10
C-1 100

SONG
`
	ts, ok := run_one_tick(t, src)
	defer delete(ts.notes)
	testing.expect(t, ok)
	testing.expect_value(t, len(ts.notes), 1)
	testing.expect_value(t, ts.notes[0].number, i32(60))
}


@(test)
test_predicate_cross_field_mod1_geq_mod2 :: proc(t: ^testing.T) {
	src := `INNER:
if mod1 >= mod2
C4 1
else
C5 1
end
C-1 100

SONG:
INNER mod1=3 mod2=10
C-1 100

SONG
`
	ts, ok := run_one_tick(t, src)
	defer delete(ts.notes)
	testing.expect(t, ok)
	testing.expect_value(t, len(ts.notes), 1)
	testing.expect_value(t, ts.notes[0].number, i32(72))
}


@(test)
test_predicate_cross_field_trans_lt_mod3 :: proc(t: ^testing.T) {
	src := `INNER:
if trans < mod3
C4 1
else
C5 1
end
C-1 100

SONG:
INNER trans=2 mod3=10
C-1 100

SONG
`
	ts, ok := run_one_tick(t, src)
	defer delete(ts.notes)
	testing.expect(t, ok)
	testing.expect_value(t, len(ts.notes), 1)
	testing.expect_value(t, ts.notes[0].number, i32(62))
}


@(test)
test_predicate_constant_on_lhs :: proc(t: ^testing.T) {
	src := `INNER:
if 5 < trans
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
	testing.expect(t, ok)
	testing.expect_value(t, len(ts.notes), 1)
	testing.expect_value(t, ts.notes[0].number, i32(70))
}


@(test)
test_predicate_mod_inherited_through_nested :: proc(t: ^testing.T) {
	src := `INNER:
if mod1 > 5
C4 1
else
C5 1
end
C-1 100

OUTER:
INNER mod1+=10
C-1 100

SONG:
OUTER mod1=2
C-1 100

SONG
`
	ts, ok := run_one_tick(t, src)
	defer delete(ts.notes)
	testing.expect(t, ok)
	testing.expect_value(t, len(ts.notes), 1)
	testing.expect_value(t, ts.notes[0].number, i32(60))
}
