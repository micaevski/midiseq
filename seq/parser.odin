package seq

import "core:fmt"
import "core:mem"
import "core:strconv"


Parser :: struct {
	src:     string,
	pos:     int,
	line:    int,
	col:     int,
	symbols: map[string]Event_Index,
}


// Parse `src` as a sequence of top-level `IDENT = [...]` timeline
// definitions. References inside a list must resolve to a timeline
// that has already been defined earlier in the source. The last
// definition becomes the root.
parse_source :: proc(sequencer: ^Sequencer, src: string) -> (root: Event_Index, ok: bool) {
	backing := make([]byte, 256 * 1024)
	defer delete(backing)

	arena: mem.Arena
	mem.arena_init(&arena, backing)
	parse_alloc := mem.arena_allocator(&arena)

	parser := Parser {
		src     = src,
		line    = 1,
		col     = 1,
		symbols = make(map[string]Event_Index, 16, parse_alloc),
	}

	// Pass 1: discover every top-level `IDENT = [...]` and reserve a
	// Timeline event for it in the pool. Bodies are skipped by
	// balancing brackets.
	if !pass_1(sequencer, &parser) do return NIL_EVENT, false

	// Pass 2: parse each body and populate its Timeline.
	parser.pos = 0
	parser.line = 1
	parser.col = 1
	root = pass_2(sequencer, &parser)
	if root == NIL_EVENT do return NIL_EVENT, false

	return root, true
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

		idx := event_alloc(sequencer)
		if idx == NIL_EVENT {
			parse_error(p, "event pool full")
			return false
		}
		event_get(sequencer, idx).kind = Timeline{}

		p.symbols[name] = idx

		if !skip_list(p) do return false
	}
	return true
}


@(private)
pass_2 :: proc(sequencer: ^Sequencer, p: ^Parser) -> Event_Index {
	last := NIL_EVENT
	for {
		skip_ws(p)
		if p.pos >= len(p.src) do break

		name, ok := parse_ident(p)
		if !ok do return NIL_EVENT
		if !expect(p, '=') do return NIL_EVENT

		idx := p.symbols[name]
		if !parse_list_into(p, sequencer, idx) do return NIL_EVENT

		last = idx
	}
	return last
}


@(private)
parse_list_into :: proc(p: ^Parser, sequencer: ^Sequencer, parent: Event_Index) -> bool {
	if !expect(p, '[') do return false

	skip_ws(p)
	if p.pos < len(p.src) && p.src[p.pos] == ']' {
		p.pos += 1
		p.col += 1
		return true
	}

	for {
		if !parse_element(p, sequencer, parent) do return false

		skip_ws(p)
		if p.pos >= len(p.src) {
			parse_error(p, "unterminated list")
			return false
		}
		c := p.src[p.pos]
		if c == ']' {
			p.pos += 1
			p.col += 1
			return true
		}
		if c != ',' {
			parse_error(p, "expected ',' or ']'")
			return false
		}
		p.pos += 1
		p.col += 1
	}
}


@(private)
parse_element :: proc(p: ^Parser, sequencer: ^Sequencer, parent: Event_Index) -> bool {
	if !expect(p, '(') do return false

	beat, ok1 := parse_number(p)
	if !ok1 {parse_error(p, "expected beat"); return false}
	if !expect(p, ',') do return false

	skip_ws(p)
	if p.pos >= len(p.src) {parse_error(p, "expected payload"); return false}

	c := p.src[p.pos]
	if is_alpha(c) || c == '_' {
		// (beat, Name) - timeline reference, shares the target's child chain.
		name, _ := parse_ident(p)
		target, exists := p.symbols[name]
		if !exists {
			parse_error(p, "undefined reference: %s", name)
			return false
		}

		target_first := event_get(sequencer, target).kind.(Timeline).first
		add_event(
			sequencer,
			parent,
			Event{beat = beat, kind = Timeline{first = target_first}},
		)
	} else {
		// (beat, duration, (key, vel)) - note.
		duration, ok2 := parse_number(p)
		if !ok2 {parse_error(p, "expected duration"); return false}
		if !expect(p, ',') do return false
		if !expect(p, '(') do return false
		key, ok3 := parse_number(p)
		if !ok3 {parse_error(p, "expected key"); return false}
		if !expect(p, ',') do return false
		vel, ok4 := parse_number(p)
		if !ok4 {parse_error(p, "expected velocity"); return false}
		if !expect(p, ')') do return false

		add_event(
			sequencer,
			parent,
			Event {
				beat = beat,
				kind = Note{number = i32(key), velocity = i32(vel), duration = duration},
			},
		)
	}

	if !expect(p, ')') do return false
	return true
}


// ===== Lex helpers =====

@(private)
skip_ws :: proc(p: ^Parser) {
	for p.pos < len(p.src) {
		switch p.src[p.pos] {
		case ' ', '\t', '\r':
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
