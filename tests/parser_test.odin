package tests

import "../source/seq"
import "core:os"
import "core:testing"


// Regression test for a bug where `parse_file` loaded the file bytes
// into the scratch arena and `parse_source` then reset the same arena
// mid-parse — corrupting the source bytes. Hits the recursive-macro
// path (which substitutes/allocates in scratch) so the corruption is
// reliable.
@(test)
test_parse_file_recursive_macro :: proc(t: ^testing.T) {
	src := `KICK:
P1O3 1

ON_EACH(t,d):
$t! 1
ON_EACH($t,$d)! 2 trans=$d

SONG:
ON_EACH(KICK,3d) chan=2 scale=CPm
SONG! 5

SONG
`
	path := "build/parse_file_test.midiseq"
	werr := os.write_entire_file(path, transmute([]u8)src)
	testing.expect_value(t, werr, os.Error{})
	defer os.remove(path)

	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)

	_, ok := seq.parse_file(&parser, path)
	testing.expect(t, ok, "parse_file should not corrupt source bytes mid-parse")
}


// ============================================================================
// Source-chain layout tests for parse_if_block.
// These assert directly against `parser.source` after a parse so we
// know the structure the runtime is going to walk, independent of any
// runtime behaviour.
// ============================================================================


// Resolve a label header to its first chain-event index.
@(private = "file")
chain_first :: proc(parser: ^seq.Parser, name: string) -> seq.Source_Index {
	idx := parser.names.by_name[name]
	return seq.source_get(&parser.source, idx).kind.(seq.Source_Timeline).first
}


@(test)
test_parse_fork_chain_then_only_terminal :: proc(t: ^testing.T) {
	// `if X / C4 / end` with nothing after `end`. Expected layout in
	// INNER's chain:
	//   fork → C4 → NIL
	//   fork.else_first = NIL  (no else branch)
	src := `INNER:
if trans > 5
C4 1
end
`
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)
	_, ok := seq.parse_source(&parser, src)
	testing.expect(t, ok, "parse should succeed")

	fork_idx := chain_first(&parser, "INNER")
	fork_event := seq.source_get(&parser.source, fork_idx)
	fork, is_fork := fork_event.kind.(seq.Source_Fork)
	testing.expect(t, is_fork, "INNER's first event should be the fork")
	testing.expect_value(t, fork.else_first, seq.NIL_SOURCE)

	c4_idx := fork_event.next
	testing.expect(t, c4_idx != seq.NIL_SOURCE, "fork.next should reach C4")

	c4_event := seq.source_get(&parser.source, c4_idx)
	_, is_note := c4_event.kind.(seq.Source_Note)
	testing.expect(t, is_note, "fork.next should be a note")
	testing.expect_value(t, c4_event.next, seq.NIL_SOURCE)
}


@(test)
test_parse_fork_chain_then_else_terminal :: proc(t: ^testing.T) {
	// `if X / C4 / else / C5 / end` with nothing after `end`. Expected:
	//   main:        fork → C4 → NIL
	//   else-branch: C5 → NIL  (reached only via fork.else_first)
	src := `INNER:
if trans > 5
C4 1
else
C5 1
end
`
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)
	_, ok := seq.parse_source(&parser, src)
	testing.expect(t, ok, "parse should succeed")

	fork_idx := chain_first(&parser, "INNER")
	fork_event := seq.source_get(&parser.source, fork_idx)
	fork, is_fork := fork_event.kind.(seq.Source_Fork)
	testing.expect(t, is_fork)

	c4_idx := fork_event.next
	c4_event := seq.source_get(&parser.source, c4_idx)
	_, is_note := c4_event.kind.(seq.Source_Note)
	testing.expect(t, is_note, "fork.next should be then-branch C4")
	testing.expect_value(t, c4_event.next, seq.NIL_SOURCE)

	testing.expect(t, fork.else_first != seq.NIL_SOURCE)
	c5_event := seq.source_get(&parser.source, fork.else_first)
	_, is_else_note := c5_event.kind.(seq.Source_Note)
	testing.expect(t, is_else_note, "fork.else_first should be else-branch C5")
	testing.expect_value(t, c5_event.next, seq.NIL_SOURCE)

	// fork.else_first must be a different event from fork.next
	testing.expect(t, fork.else_first != c4_idx, "else and then heads must differ")
}


@(test)
test_parse_fork_chain_then_else_with_post_if :: proc(t: ^testing.T) {
	// Both branch tails should rejoin on the post-if event when one is
	// added after `end`:
	//   main:        fork → C4 → C6 → NIL
	//   else-branch: C5 → C6  (patched via pending_tails when C6 added)
	src := `INNER:
if trans > 5
C4 1
else
C5 1
end
C6 2
`
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)
	_, ok := seq.parse_source(&parser, src)
	testing.expect(t, ok, "parse should succeed")

	fork_idx := chain_first(&parser, "INNER")
	fork_event := seq.source_get(&parser.source, fork_idx)
	fork, _ := fork_event.kind.(seq.Source_Fork)

	c4_idx := fork_event.next
	c4_event := seq.source_get(&parser.source, c4_idx)

	c6_idx := c4_event.next
	testing.expect(t, c6_idx != seq.NIL_SOURCE, "C4.next should reach the post-if event")
	c6_event := seq.source_get(&parser.source, c6_idx)
	_, is_post_note := c6_event.kind.(seq.Source_Note)
	testing.expect(t, is_post_note)
	testing.expect_value(t, c6_event.next, seq.NIL_SOURCE)

	// Else-branch tail rejoins on the same C6 idx.
	c5_idx := fork.else_first
	c5_event := seq.source_get(&parser.source, c5_idx)
	testing.expect_value(t, c5_event.next, c6_idx)
}


@(test)
test_parse_fork_chain_else_branch_off_main :: proc(t: ^testing.T) {
	// Sanity check: the else-branch must be reachable ONLY via
	// fork.else_first. Walking parent.first via .next must never visit
	// any else-branch event.
	src := `INNER:
if trans > 5
C4 1
else
C5 1
end
C6 2
`
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)
	_, ok := seq.parse_source(&parser, src)
	testing.expect(t, ok)

	inner_first := chain_first(&parser, "INNER")
	fork, _ := seq.source_get(&parser.source, inner_first).kind.(seq.Source_Fork)
	c5_idx := fork.else_first

	walker := inner_first
	for walker != seq.NIL_SOURCE {
		testing.expect(t, walker != c5_idx, "main chain walk must not visit else-branch event")
		walker = seq.source_get(&parser.source, walker).next
	}
}


@(test)
test_macro_basic :: proc(t: ^testing.T) {
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)

	src := `ARP(beat, oct):
P1O$oct $beat
P3O$oct $beat

SONG:
ARP(1, 3)

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
C3 1

ON_EACH(t):
$t! 1
$t! 2
$t! 3

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
C3 1
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
P1O$p 1
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
P1O3 1

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
C3 1

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
P1O$x 1

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


@(test)
test_macro_param_spread_self_call :: proc(t: ^testing.T) {
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)

	src := `ROLL(n, dv):
$n
ROLL(...)! 2 trans=$dv

SONG:
ROLL(C3, 1)

SONG
`
	_, ok := seq.parse_source(&parser, src)
	testing.expect(t, ok, "(...) self-call sugar should parse and memoize")
	testing.expect_value(t, len(parser.macro_instances), 1)
}


@(test)
test_macro_param_spread_cross_call :: proc(t: ^testing.T) {
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)

	src := `UP(t, d):
$t
DOWN(...)! 2 trans=$d

DOWN(t, d):
$t
UP(...)! 2 trans=-$d

SONG:
UP(C3, 1)

SONG
`
	_, ok := seq.parse_source(&parser, src)
	testing.expect(t, ok, "(...) cross-macro forwarding should parse")
}


@(test)
test_macro_param_spread_with_whitespace :: proc(t: ^testing.T) {
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)

	src := `M(p):
$p
M( ... )! 2

SONG:
M(C3)

SONG
`
	_, ok := seq.parse_source(&parser, src)
	testing.expect(t, ok, "whitespace inside ( ... ) should be tolerated")
}


@(test)
test_macro_param_spread_does_not_affect_explicit_calls :: proc(t: ^testing.T) {
	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)

	src := `M(p, q):
P1O$p 1
M($p, $q)! 2

SONG:
M(3, 2)

SONG
`
	_, ok := seq.parse_source(&parser, src)
	testing.expect(t, ok, "explicit (a, b) form should be unaffected by the spread sugar")
}
