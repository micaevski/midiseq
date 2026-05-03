package tests

import "../source/seq"
import "core:testing"


@(private = "file")
Captured_CC :: struct {
	channel: i32,
	number:  i32,
	value:   i32,
	beat:    f32,
}

@(private = "file")
CC_Sink :: struct {
	cc_events: [dynamic]Captured_CC,
}

@(private = "file")
cc_note_on :: proc(user: rawptr, channel, number, velocity: i32, beat: f32) {}

@(private = "file")
cc_note_off :: proc(user: rawptr, channel, number: i32, beat: f32) {}

@(private = "file")
cc_capture :: proc(user: rawptr, channel, number, value: i32, beat: f32) {
	sink := cast(^seq.Sink)user
	ts := cast(^CC_Sink)sink.user
	append(&ts.cc_events, Captured_CC{channel, number, value, beat})
}

@(private = "file")
make_cc_sink :: proc(ts: ^CC_Sink) -> seq.Sink {
	return seq.Sink{user = ts, note_on = cc_note_on, note_off = cc_note_off, cc = cc_capture}
}


// Smoke check: a CC inside a ref'd sub-timeline fires.
@(test)
test_cc_basic_via_ref :: proc(t: ^testing.T) {
	src := `INNER:
CC74 1 val=42
C-1 100

SONG:
INNER
C-1 100

SONG
`
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)
	root, p_ok := seq.parse_source(&parser, src)
	testing.expect(t, p_ok)

	ts: CC_Sink
	defer delete(ts.cc_events)
	sink := make_cc_sink(&ts)
	sequencer := seq.make_sequencer(sink)
	defer seq.destroy_sequencer(sequencer)
	seq.adapt_to_source(sequencer, &parser, root)
	seq.start(sequencer)
	for b in 0 ..< 3 {
		seq.tick(sequencer, f32(b))
	}
	testing.expect_value(t, len(ts.cc_events), 1)
	testing.expect_value(t, ts.cc_events[0].value, i32(42))
}


// `mod1+=N` on a ref applies an additive update for the spawned child;
// a child-level CC event with `val=K+mod1` reads the accumulated mod.
@(test)
test_cc_mod_additive :: proc(t: ^testing.T) {
	src := `INNER:
CC74 1 val=10+mod1
C-1 100

SONG:
INNER mod1+=20
C-1 100

SONG
`
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)
	root, p_ok := seq.parse_source(&parser, src)
	testing.expect(t, p_ok)

	ts: CC_Sink
	defer delete(ts.cc_events)
	sink := make_cc_sink(&ts)
	sequencer := seq.make_sequencer(sink)
	defer seq.destroy_sequencer(sequencer)
	seq.adapt_to_source(sequencer, &parser, root)
	seq.start(sequencer)
	for b in 0 ..< 3 {
		seq.tick(sequencer, f32(b))
	}
	testing.expect_value(t, len(ts.cc_events), 1)
	testing.expect_value(t, ts.cc_events[0].number, i32(74))
	testing.expect_value(t, ts.cc_events[0].value, i32(30))
}


// `mod1=N` on a ref hard-sets the child's mod, ignoring any accumulated
// value from outer refs.
@(test)
test_cc_mod_set_overrides :: proc(t: ^testing.T) {
	src := `INNER:
CC74 1 val=mod1
C-1 100

SONG:
INNER mod1+=20 mod1=5
C-1 100

SONG
`
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)
	root, p_ok := seq.parse_source(&parser, src)
	testing.expect(t, p_ok)

	ts: CC_Sink
	defer delete(ts.cc_events)
	sink := make_cc_sink(&ts)
	sequencer := seq.make_sequencer(sink)
	defer seq.destroy_sequencer(sequencer)
	seq.adapt_to_source(sequencer, &parser, root)
	seq.start(sequencer)
	for b in 0 ..< 3 {
		seq.tick(sequencer, f32(b))
	}
	testing.expect_value(t, len(ts.cc_events), 1)
	// `mod1=5` written after `mod1+=20` wins.
	testing.expect_value(t, ts.cc_events[0].value, i32(5))
}


// Negative literals: `mod1=-N`, `mod1+=-N`, and the explicit `-=N`
// subtractive operator all yield the same effect.
@(test)
test_cc_mod_negative_literals :: proc(t: ^testing.T) {
	src := `INNER:
CC1 1 val=50+mod1
CC2 1 val=50+mod2
CC3 1 val=50+mod3
C-1 100

SONG:
INNER mod1=-10 mod2+=-20 mod3-=15
C-1 100

SONG
`
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)
	root, p_ok := seq.parse_source(&parser, src)
	testing.expect(t, p_ok)

	ts: CC_Sink
	defer delete(ts.cc_events)
	sink := make_cc_sink(&ts)
	sequencer := seq.make_sequencer(sink)
	defer seq.destroy_sequencer(sequencer)
	seq.adapt_to_source(sequencer, &parser, root)
	seq.start(sequencer)
	for b in 0 ..< 3 {
		seq.tick(sequencer, f32(b))
	}
	cc1, cc2, cc3: i32 = -1, -1, -1
	for ev in ts.cc_events {
		if ev.number == 1 do cc1 = ev.value
		if ev.number == 2 do cc2 = ev.value
		if ev.number == 3 do cc3 = ev.value
	}
	testing.expect_value(t, cc1, i32(40))
	testing.expect_value(t, cc2, i32(30))
	testing.expect_value(t, cc3, i32(35))
}


// Mods on independent registers don't interfere.
@(test)
test_cc_mod_independent_registers :: proc(t: ^testing.T) {
	src := `INNER:
CC1 1 val=mod1
CC2 1 val=mod2
C-1 100

SONG:
INNER mod1+=11 mod2+=22
C-1 100

SONG
`
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)
	root, p_ok := seq.parse_source(&parser, src)
	testing.expect(t, p_ok)

	ts: CC_Sink
	defer delete(ts.cc_events)
	sink := make_cc_sink(&ts)
	sequencer := seq.make_sequencer(sink)
	defer seq.destroy_sequencer(sequencer)
	seq.adapt_to_source(sequencer, &parser, root)
	seq.start(sequencer)
	for b in 0 ..< 3 {
		seq.tick(sequencer, f32(b))
	}
	cc1_val: i32 = -1
	cc2_val: i32 = -1
	for ev in ts.cc_events {
		if ev.number == 1 do cc1_val = ev.value
		if ev.number == 2 do cc2_val = ev.value
	}
	testing.expect_value(t, cc1_val, i32(11))
	testing.expect_value(t, cc2_val, i32(22))
}
