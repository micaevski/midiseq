package seq

import "core:fmt"
import "core:mem"
import "core:strconv"


Parser :: struct {
	src:     string,
	pos:     int,
	line:    int,
	col:     int,
	symbols: map[string]Source_Index,
}


// Parse `src` as a sequence of top-level `IDENT = [...]` timeline
// definitions. References inside a list must resolve to a timeline
// that has already been defined earlier in the source. The last
// definition becomes the root.
parse_source :: proc(sequencer: ^Sequencer, src: string) -> (root: Source_Index, ok: bool) {
	backing := make([]byte, 256 * 1024)
	defer delete(backing)

	arena: mem.Arena
	mem.arena_init(&arena, backing)
	parse_alloc := mem.arena_allocator(&arena)

	parser := Parser {
		src     = src,
		line    = 1,
		col     = 1,
		symbols = make(map[string]Source_Index, 16, parse_alloc),
	}

	// Pass 1: discover every top-level `IDENT = [...]` and reserve a
	// Timeline event for it in the pool. Bodies are skipped by
	// balancing brackets.
	if !pass_1(sequencer, &parser) do return NIL_SOURCE, false

	// Pass 2: parse each body and populate its Timeline. References
	// stash the target's index in their `first` field (unresolved).
	parser.pos = 0
	parser.line = 1
	parser.col = 1
	root = pass_2(sequencer, &parser)
	if root == NIL_SOURCE do return NIL_SOURCE, false

	// Pass 3: every top-level body is populated now, so we can rewrite
	// each reference's stashed target-index into the target's actual
	// children chain head.
	resolve_references(sequencer, &parser)

	return root, true
}


// For each top-level timeline, walk its direct children. Any child that
// is a Timeline is a reference, and its `first` currently holds the
// target's event index. Replace it with the target's children chain head.
@(private)
resolve_references :: proc(sequencer: ^Sequencer, p: ^Parser) {
	for _, top_index in p.symbols {
		top_event := source_get(sequencer, top_index)
		top_timeline, ok := top_event.kind.(Timeline)
		if !ok do continue

		child_index := top_timeline.first
		for child_index != NIL_SOURCE {
			child := source_get(sequencer, child_index)
			next := child.next
			if _, is_timeline := child.kind.(Timeline); is_timeline {
				ref_timeline := &child.kind.(Timeline)
				target := ref_timeline.first
				ref_timeline.first = source_get(sequencer, target).kind.(Timeline).first
			}
			child_index = next
		}
	}
}


@(private)
pass_1 :: proc(sequencer: ^Sequencer, p: ^Parser) -> bool {
	for {
		skip_ws(p)
		if p.pos >= len(p.src) do break

		name, ok := parse_ident(p)
		if !ok {
			parse_error(p, "expected identifier")
			return false
		}
		if !expect(p, '=') do return false

		// Top-level directives: `SEED = N` sets the RNG seed.
		if name == "SEED" {
			n, n_ok := parse_number(p)
			if !n_ok {parse_error(p, "expected SEED value"); return false}
			sequencer.rng_state = u32(n)
			continue
		}

		idx := source_alloc(sequencer)
		if idx == NIL_SOURCE {
			parse_error(p, "event pool full")
			return false
		}
		top_event := source_get(sequencer, idx)
		top_event.chance = 100
		top_event.kind = Timeline{rate = 1}

		p.symbols[name] = idx

		if !skip_list(p) do return false
	}
	return true
}


@(private)
pass_2 :: proc(sequencer: ^Sequencer, p: ^Parser) -> Source_Index {
	last := NIL_SOURCE
	for {
		skip_ws(p)
		if p.pos >= len(p.src) do break

		name, ok := parse_ident(p)
		if !ok do return NIL_SOURCE
		if !expect(p, '=') do return NIL_SOURCE

		// SEED was consumed in pass_1; skip over its value here.
		if name == "SEED" {
			_, _ = parse_number(p)
			continue
		}

		idx := p.symbols[name]
		if !parse_list_into(p, sequencer, idx) do return NIL_SOURCE

		last = idx
	}
	return last
}


@(private)
parse_list_into :: proc(p: ^Parser, sequencer: ^Sequencer, parent: Source_Index) -> bool {
	if !expect(p, '[') do return false

	for {
		skip_ws(p)
		if p.pos >= len(p.src) {
			parse_error(p, "unterminated list")
			return false
		}
		if p.src[p.pos] == ']' {
			p.pos += 1
			p.col += 1
			return true
		}
		if !parse_element(p, sequencer, parent) do return false
	}
}


// An element is either a note call or a timeline reference call:
//   note( TIME PITCH [vel=V] [dur=D] )
//   NAME( TIME )
// Commas between tokens are optional (treated as whitespace).
@(private)
parse_element :: proc(p: ^Parser, sequencer: ^Sequencer, parent: Source_Index) -> bool {
	name, ok := parse_ident(p)
	if !ok {
		parse_error(p, "expected 'note' or a timeline name")
		return false
	}

	if name == "note" do return parse_note_call(p, sequencer, parent)

	target, exists := p.symbols[name]
	if !exists {
		parse_error(p, "undefined reference: %s", name)
		return false
	}

	if !expect(p, '(') do return false
	beat, ok_b := parse_number(p)
	if !ok_b {parse_error(p, "expected time"); return false}

	trans: i32 = 0
	rate: f32 = 1
	chance: i32 = 100
	for {
		skip_ws(p)
		if p.pos >= len(p.src) {
			parse_error(p, "unterminated reference")
			return false
		}
		if p.src[p.pos] == ')' do break

		arg_name, ok_a := parse_ident(p)
		if !ok_a {parse_error(p, "expected argument name or ')'"); return false}
		if !expect(p, '=') do return false

		switch arg_name {
		case "trans":
			v, ok := parse_number(p)
			if !ok {parse_error(p, "expected transposition"); return false}
			trans = i32(v)
		case "rate":
			v, ok := parse_number(p)
			if !ok {parse_error(p, "expected rate"); return false}
			rate = v
		case "chance":
			c, ok := parse_number(p)
			if !ok {parse_error(p, "expected chance"); return false}
			chance = i32(c)
		case:
			parse_error(p, "unknown reference argument: %s", arg_name)
			return false
		}
	}
	if !expect(p, ')') do return false

	// Stash the target's index in `first`. It gets rewritten to the
	// target's actual children chain head by resolve_references after
	// every top-level body has been parsed.
	add_event(
		sequencer,
		parent,
		Event {
			beat = beat,
			chance = chance,
			kind = Timeline{first = target, transposition = trans, rate = rate},
		},
	)
	return true
}


NOTE_DEFAULT_VELOCITY :: 100
NOTE_DEFAULT_DURATION :: 1.0
NOTE_DEFAULT_CHANCE :: 100

// note( TIME PITCH [vel=V] [dur=D] [chance=C] )
@(private)
parse_note_call :: proc(p: ^Parser, sequencer: ^Sequencer, parent: Source_Index) -> bool {
	if !expect(p, '(') do return false

	beat, ok_b := parse_number(p)
	if !ok_b {parse_error(p, "expected time"); return false}

	pitch, ok_p := parse_key(p)
	if !ok_p {parse_error(p, "expected pitch"); return false}

	vel: i32 = NOTE_DEFAULT_VELOCITY
	dur: f32 = NOTE_DEFAULT_DURATION
	chance: i32 = NOTE_DEFAULT_CHANCE

	for {
		skip_ws(p)
		if p.pos >= len(p.src) {
			parse_error(p, "unterminated note call")
			return false
		}
		if p.src[p.pos] == ')' do break

		arg_name, ok_a := parse_ident(p)
		if !ok_a {parse_error(p, "expected argument name or ')'"); return false}
		if !expect(p, '=') do return false

		switch arg_name {
		case "vel":
			v, ok := parse_number(p)
			if !ok {parse_error(p, "expected velocity"); return false}
			vel = i32(v)
		case "dur":
			d, ok := parse_number(p)
			if !ok {parse_error(p, "expected duration"); return false}
			dur = d
		case "chance":
			c, ok := parse_number(p)
			if !ok {parse_error(p, "expected chance"); return false}
			chance = i32(c)
		case:
			parse_error(p, "unknown note argument: %s", arg_name)
			return false
		}
	}
	if !expect(p, ')') do return false

	add_event(
		sequencer,
		parent,
		Event {
			beat = beat,
			chance = chance,
			kind = Note{number = pitch, velocity = vel, duration = dur},
		},
	)
	return true
}


// ===== Lex helpers =====

@(private)
skip_ws :: proc(p: ^Parser) {
	for p.pos < len(p.src) {
		switch p.src[p.pos] {
		case ' ', '\t', '\r', ',':
			p.pos += 1
			p.col += 1
		case '\n':
			p.pos += 1
			p.line += 1
			p.col = 1
		case:
			return
		}
	}
}

@(private)
expect :: proc(p: ^Parser, ch: u8) -> bool {
	skip_ws(p)
	if p.pos >= len(p.src) || p.src[p.pos] != ch {
		parse_error(p, "expected '%c'", rune(ch))
		return false
	}
	p.pos += 1
	p.col += 1
	return true
}

@(private)
parse_ident :: proc(p: ^Parser) -> (string, bool) {
	skip_ws(p)
	start := p.pos
	if p.pos >= len(p.src) do return "", false
	c := p.src[p.pos]
	if !(is_alpha(c) || c == '_') do return "", false
	for p.pos < len(p.src) {
		c = p.src[p.pos]
		if is_alpha(c) || is_digit(c) || c == '_' {
			p.pos += 1
			p.col += 1
		} else {
			break
		}
	}
	return p.src[start:p.pos], true
}

// A MIDI key can be written either as a raw number (e.g. 60) or as a
// note name with an optional accidental and an octave (e.g. C4, F#3, Ab-1).
// Sharp is '#'; flat is lowercase 'b' (uppercase B is a note letter).
// The letter itself is case-insensitive. MIDI 60 = C4.
@(private)
parse_key :: proc(p: ^Parser) -> (i32, bool) {
	skip_ws(p)
	if p.pos >= len(p.src) do return 0, false

	c := p.src[p.pos]
	upper := c
	if upper >= 'a' && upper <= 'z' do upper -= 'a' - 'A'
	if upper >= 'A' && upper <= 'G' do return parse_note_name(p)

	n, ok := parse_number(p)
	if !ok do return 0, false
	return i32(n), true
}

@(private)
parse_note_name :: proc(p: ^Parser) -> (i32, bool) {
	c := p.src[p.pos]
	if c >= 'a' && c <= 'z' do c -= 'a' - 'A'

	base: i32
	switch c {
	case 'C':
		base = 0
	case 'D':
		base = 2
	case 'E':
		base = 4
	case 'F':
		base = 5
	case 'G':
		base = 7
	case 'A':
		base = 9
	case 'B':
		base = 11
	case:
		return 0, false
	}
	p.pos += 1
	p.col += 1

	if p.pos < len(p.src) {
		acc := p.src[p.pos]
		if acc == '#' {
			base += 1
			p.pos += 1
			p.col += 1
		} else if acc == 'b' {
			base -= 1
			p.pos += 1
			p.col += 1
		}
	}

	octave_sign: i32 = 1
	if p.pos < len(p.src) && p.src[p.pos] == '-' {
		octave_sign = -1
		p.pos += 1
		p.col += 1
	}
	if p.pos >= len(p.src) || !is_digit(p.src[p.pos]) {
		parse_error(p, "expected octave after note name")
		return 0, false
	}

	octave: i32 = 0
	for p.pos < len(p.src) && is_digit(p.src[p.pos]) {
		octave = octave * 10 + i32(p.src[p.pos] - '0')
		p.pos += 1
		p.col += 1
	}
	octave *= octave_sign

	return (octave + 1) * 12 + base, true
}

@(private)
parse_number :: proc(p: ^Parser) -> (f32, bool) {
	skip_ws(p)
	start := p.pos
	if p.pos < len(p.src) && (p.src[p.pos] == '-' || p.src[p.pos] == '+') {
		p.pos += 1
		p.col += 1
	}
	has_digit := false
	for p.pos < len(p.src) && is_digit(p.src[p.pos]) {
		p.pos += 1
		p.col += 1
		has_digit = true
	}
	if p.pos < len(p.src) && p.src[p.pos] == '.' {
		p.pos += 1
		p.col += 1
		for p.pos < len(p.src) && is_digit(p.src[p.pos]) {
			p.pos += 1
			p.col += 1
			has_digit = true
		}
	}
	if !has_digit {
		p.pos = start
		return 0, false
	}
	n, ok := strconv.parse_f32(p.src[start:p.pos])
	return n, ok
}

// Advance past a balanced '[' ... ']' block.
@(private)
skip_list :: proc(p: ^Parser) -> bool {
	skip_ws(p)
	if p.pos >= len(p.src) || p.src[p.pos] != '[' {
		parse_error(p, "expected '['")
		return false
	}
	depth := 0
	for p.pos < len(p.src) {
		switch p.src[p.pos] {
		case '[':
			depth += 1
			p.pos += 1
			p.col += 1
		case ']':
			depth -= 1
			p.pos += 1
			p.col += 1
			if depth == 0 do return true
		case '\n':
			p.pos += 1
			p.line += 1
			p.col = 1
		case:
			p.pos += 1
			p.col += 1
		}
	}
	parse_error(p, "unterminated '['")
	return false
}

@(private)
is_alpha :: proc(c: u8) -> bool {
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
}

@(private)
is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

@(private)
parse_error :: proc(p: ^Parser, format: string, args: ..any) {
	fmt.eprintf("parse error at %d:%d: ", p.line, p.col)
	fmt.eprintfln(format, ..args)
}
