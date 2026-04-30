package tests

import "../source/seq"
import "core:testing"


@(test)
test_macro_basic :: proc(t: ^testing.T) {
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)

	src := `ARP(beat, oct):
P1O$oct $beat
P3O$oct $beat

SONG:
ARP(0, 3)

SONG
`
	root, ok := seq.parse_source(&parser, src)
	testing.expect(t, ok, "macro parse should succeed")
	testing.expect(t, root != seq.NIL_SOURCE, "expected non-nil root")
}


@(test)
test_macro_timeline_param :: proc(t: ^testing.T) {
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)

	src := `KICK:
C3 0

ON_EACH(t):
$t! 0
$t! 1
$t! 2

SONG:
ON_EACH(KICK)

SONG
`
	_, ok := seq.parse_source(&parser, src)
	testing.expect(t, ok, "timeline-param macro should parse")
}


@(test)
test_macro_arity_mismatch :: proc(t: ^testing.T) {
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)

	src := `M(a, b):
C3 $a

SONG:
M(1)

SONG
`
	_, ok := seq.parse_source(&parser, src)
	testing.expect(t, !ok, "arity mismatch should fail")
}


@(test)
test_macro_undefined :: proc(t: ^testing.T) {
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)

	src := `SONG:
NOPE(1)

SONG
`
	_, ok := seq.parse_source(&parser, src)
	testing.expect(t, !ok, "undefined macro should fail")
}


@(test)
test_macro_self_recursive :: proc(t: ^testing.T) {
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)

	// Self-reference resolves to the in-progress instance via
	// memoization — same as `BASS!` inside `BASS:` — so this should
	// parse cleanly without hitting the depth limit.
	src := `R():
C3 0
R()

SONG:
R()

SONG
`
	_, ok := seq.parse_source(&parser, src)
	testing.expect(t, ok, "self-recursive macro should parse via memoization")
}


@(test)
test_macro_recursive_with_params :: proc(t: ^testing.T) {
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)

	// Two distinct argument tuples → two instances, each containing
	// its own substituted self-reference resolved via memoization.
	src := `M(p):
P1O$p 0
M($p)!

SONG:
M(3)
M(3)
M(4)

SONG
`
	_, ok := seq.parse_source(&parser, src)
	testing.expect(t, ok, "param-substituted self-recursion should parse")
	testing.expect_value(t, len(parser.macro_instances), 2)
}


@(test)
test_macro_arg_with_unit_suffix :: proc(t: ^testing.T) {
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)

	// `3d` and similar number-with-unit-suffix tokens (matching the
	// `trans=2d` syntax for scale-degrees) should pass through as a
	// single argument rather than being split into `3` and `d`.
	src := `KICK:
P1O3 0

ON_EACH(t, d):
$t! 1
ON_EACH($t, $d)! 2 trans=$d

SONG:
ON_EACH(KICK, 3d) chan=2 scale=CPm

SONG
`
	_, ok := seq.parse_source(&parser, src)
	testing.expect(t, ok, "macro should accept `3d` as a single arg")
}


@(test)
test_macro_invocation_with_modifiers :: proc(t: ^testing.T) {
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)

	// Exercises a real-world combination that previously failed: a
	// macro invocation followed by `!`, a beat, and a kwarg
	// (`trans=1d`). Regression test for the missing `!` consumption
	// after the closing paren.
	src := `KICK:
C3 0

ON_EACH(t):
$t! 1
ON_EACH($t)! 2 trans=1d

SONG:
ON_EACH(KICK) chan=2
SONG! 5

SONG
`
	_, ok := seq.parse_source(&parser, src)
	testing.expect(t, ok, "macro invocation with !, beat, and kwargs should parse")
}


@(test)
test_macro_memoizes_same_args :: proc(t: ^testing.T) {
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)

	// Two invocations with the same args should share an instance —
	// only one anonymous Source_Timeline is allocated.
	src := `M(x):
P1O$x 0

SONG:
M(3)
M(3)
M(4)

SONG
`
	_, ok := seq.parse_source(&parser, src)
	testing.expect(t, ok, "memoized macro invocations should parse")
	testing.expect_value(t, len(parser.macro_instances), 2)
}
