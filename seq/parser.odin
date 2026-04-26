package seq

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"


// Parser owns the buffers it parses into. Live and parser buffers are
// ping-ponged at the call site: on a successful reparse the caller
// swaps `parser.source` ↔ `sequencer.source` and `parser.names` ↔
// `sequencer.names`, so neither side ever allocates fresh storage per
// reparse. On failure, nothing swaps — the parser's partially-written
// scratch is overwritten on the next call via the bump-pointer reset
// in `parse_source`.
//
// `rng_state` is filled from a `SEED = N` directive (if present) and
// is also intended to be transferred to the sequencer on a successful
// swap.
//
// `src`/`pos`/`line`/`col` are transient parse-time state, reinitialized
// each call. The forward `name → top-level def index` map lives on
// `names.by_name` so it ships along with the names buffer to the
// sequencer (and so `adapt_to_source` doesn't need to know about the
// parser at all).
Parser :: struct {
	source:      [dynamic]Source_Event,
	names:       Names,
	rng_state:   u32,
	play_marked: [dynamic]Source_Index,

	src:         string,
	pos:         int,
	line:        int,
	col:         int,
}


make_parser :: proc(pool_bytes: int = DEFAULT_POOL_BYTES) -> Parser {
	capacity := pool_bytes / size_of(Source_Event)
	p := Parser{}
	p.source = make_source_store(capacity)
	p.names = make_names()
	p.play_marked = make([dynamic]Source_Index, 0, 16)
	return p
}

destroy_parser :: proc(p: ^Parser) {
	delete(p.source)
	destroy_names(&p.names)
	delete(p.play_marked)
	p^ = {}
}


// Parse `src` into the parser's own buffers. On success, the caller
// swaps `parser.source`/`parser.names` into the live sequencer and
// uses the returned root index.
//
// Syntax (one element per line is the natural style; whitespace and
// blank lines are insignificant):
//
//   IDENT [chan=N]:              // begins a top-level definition
//   note(beat pitch [vel=V] [dur=D] [chance=C])
//   NAME(beat [trans=T] [rate=R] [chance=C] [free])
//   ...
//   IDENT [chan=N]:              // begins the next top-level definition
//
//   SEED = N                     // optional directive
//
// A name reference must resolve to a timeline that has already been
// defined earlier in the file. The last definition becomes the root.
parse_source :: proc(parser: ^Parser, src: string) -> (root: Source_Index, ok: bool) {
	// Wipe any leftovers from a previous parse (or from buffers we
	// just received via swap on a previous successful reparse).
	source_store_reset(&parser.source)
	names_reset(&parser.names)
	clear(&parser.play_marked)
	parser.rng_state = 0

	parser.src = src
	parser.pos = 0
	parser.line = 1
	parser.col = 1

	// Pass 1: discover every `IDENT:` header and reserve a Timeline
	// event for it. Element calls are skipped by balancing parens.
	if !pass_1(parser) do return NIL_SOURCE, false

	// Pass 2: walk the source again. Each `IDENT:` rebinds the current
	// parent; each element call is added to that parent.
	parser.pos = 0
	parser.line = 1
	parser.col = 1
	last := pass_2(parser)
	if last == NIL_SOURCE do return NIL_SOURCE, false

	// Pass 3: every top-level body is populated now, so we can rewrite
	// each reference's stashed target-index into the target's actual
	// children chain head.
	resolve_references(parser)

	// Build the dummy root: a synthetic Source_Timeline whose children
	// are LABEL(0)-style refs to every @play-marked def. If no
	// markers were given, fall back to the last definition (legacy
	// "last def is root" behavior).
	root = build_dummy_root(parser, last)
	if root == NIL_SOURCE do return NIL_SOURCE, false

	return root, true
}


@(private)
build_dummy_root :: proc(p: ^Parser, last_def: Source_Index) -> Source_Index {
	dummy_idx := source_alloc(&p.source)
	if dummy_idx == NIL_SOURCE {
		parse_error(p, "source storage full")
		return NIL_SOURCE
	}
	dummy := source_get(&p.source, dummy_idx)
	dummy.chance = 100
	dummy.kind = Source_Timeline{rate = 1, channel = -1}

	targets := p.play_marked[:]
	if len(targets) == 0 {
		// Fallback: the last definition is the implicit play target.
		targets = []Source_Index{last_def}
	}

	for target_idx in targets {
		target := source_get(&p.source, target_idx)
		target_top := target.kind.(Source_Timeline)
		ref_idx := add_source_event(
			&p.source,
			dummy_idx,
			Source_Event {
				beat = 0,
				chance = 100,
				kind = Source_Timeline {
					first = target_top.first,
					channel = target_top.channel,
					transposition = 0,
					rate = 1,
				},
			},
		)
		if ref_idx != NIL_SOURCE {
			// Carry the target's name onto the ref so adapt_to_source
			// can match new dummy-root children against old ones by name.
			if name, has_name := p.names.lookup[target_idx]; has_name {
				p.names.lookup[ref_idx] = name
			}
		}
	}

	return dummy_idx
}


// For each top-level timeline, walk its direct children. Any child that
// is a Source_Timeline is a reference, and its `first` currently holds
// the target's event index. Replace it with the target's children chain
// head.
@(private)
resolve_references :: proc(p: ^Parser) {
	for _, top_index in p.names.by_name {
		top_event := source_get(&p.source, top_index)
		top_timeline, ok := top_event.kind.(Source_Timeline)
		if !ok do continue

		child_index := top_timeline.first
		for child_index != NIL_SOURCE {
			child := source_get(&p.source, child_index)
			next := child.next
			if _, is_timeline := child.kind.(Source_Timeline); is_timeline {
				ref_timeline := &child.kind.(Source_Timeline)
				target := ref_timeline.first
				ref_timeline.first =
					source_get(&p.source, target).kind.(Source_Timeline).first
			}
			child_index = next
		}
	}
}


// Pass 1: walk the source linearly. Each `IDENT:` reserves a Timeline
// slot in the source store; element calls (`name(...)`) are skipped
// over via balanced parens. The `SEED = N` directive is consumed here
// (and again in pass 2).
@(private)
pass_1 :: proc(p: ^Parser) -> bool {
	pending_play := false
	for {
		skip_ws(p)
		if p.pos >= len(p.src) do break

		// `@play` line — flag the next IDENT: header.
		if p.src[p.pos] == '@' {
			p.pos += 1
			p.col += 1
			anno, ok_a := parse_ident(p)
			if !ok_a {parse_error(p, "expected annotation name after '@'"); return false}
			switch anno {
			case "play":
				pending_play = true
			case:
				parse_error(p, "unknown annotation: @%s", anno)
				return false
			}
			continue
		}

		name, ok := parse_ident(p)
		if !ok {
			parse_error(p, "expected identifier")
			return false
		}

		skip_ws(p)
		if p.pos >= len(p.src) {
			parse_error(p, "unexpected end of file after %s", name)
			return false
		}

		peek := p.src[p.pos]
		if peek == ':' || is_ident_start(peek) {
			if name == "SEED" {
				parse_error(p, "SEED uses '=', not ':'")
				return false
			}
			idx := source_alloc(&p.source)
			if idx == NIL_SOURCE {
				parse_error(p, "source storage full")
				return false
			}
			top_event := source_get(&p.source, idx)
			top_event.chance = 100
			top_event.kind = Source_Timeline{rate = 1, channel = -1}
			p.names.by_name[name] = idx
			if pending_play {
				append(&p.play_marked, idx)
				pending_play = false
			}
			if peek != ':' {
				if !parse_def_kwargs(p, idx) do return false
			}
			if !expect(p, ':') do return false
			// `LABEL: "path.mid"` form — skip the path here; pass_2
			// loads the file.
			skip_ws(p)
			if p.pos < len(p.src) && p.src[p.pos] == '"' {
				if _, ok_s := parse_string_literal(p); !ok_s do return false
			}
		} else {
			switch peek {
			case '=':
				if name != "SEED" {
					parse_error(p, "unexpected '='; only SEED uses '='")
					return false
				}
				p.pos += 1
				p.col += 1
				n, n_ok := parse_number(p)
				if !n_ok {parse_error(p, "expected SEED value"); return false}
				p.rng_state = u32(n)
			case '(':
				// Element call body — skip over balanced parens.
				if !skip_call_args(p) do return false
			case:
				parse_error(p, "expected ':', '=' or '(' after %s", name)
				return false
			}
		}
	}
	if pending_play {
		parse_error(p, "@play with no following label")
		return false
	}
	return true
}


// Pass 2: walk the source again. Each `IDENT:` rebinds the current
// parent; each element call is added into that parent. Refs stash the
// target's index in their `first` field — `resolve_references` rewrites
// it into the target's children-chain head once all bodies are populated.
@(private)
pass_2 :: proc(p: ^Parser) -> Source_Index {
	last := NIL_SOURCE
	current_parent := NIL_SOURCE

	for {
		skip_ws(p)
		if p.pos >= len(p.src) do break

		// `@anno` lines were consumed for their effect in pass_1; just
		// skip past them here so the surrounding loop stays in sync.
		if p.src[p.pos] == '@' {
			p.pos += 1
			p.col += 1
			_, _ = parse_ident(p)
			continue
		}

		name, ok := parse_ident(p)
		if !ok {
			parse_error(p, "expected identifier")
			return NIL_SOURCE
		}

		skip_ws(p)
		if p.pos >= len(p.src) {
			parse_error(p, "unexpected end of file after %s", name)
			return NIL_SOURCE
		}

		peek := p.src[p.pos]
		if peek == ':' || is_ident_start(peek) {
			idx := p.names.by_name[name]
			// Names from p.src are slices into the caller-owned source
			// string and disappear once parsing is done; clone into the
			// parser's names arena so they survive the swap into the
			// sequencer.
			p.names.lookup[idx], _ = strings.clone(
				name,
				mem.arena_allocator(&p.names.arena),
			)
			if peek != ':' {
				if !parse_def_kwargs(p, idx) do return NIL_SOURCE
			}
			if !expect(p, ':') do return NIL_SOURCE
			current_parent = idx
			last = idx
			// `LABEL: "path.mid"` — read the MIDI file and add a Note
			// child for each parsed note.
			skip_ws(p)
			if p.pos < len(p.src) && p.src[p.pos] == '"' {
				path, ok_s := parse_string_literal(p)
				if !ok_s do return NIL_SOURCE
				if !load_midi_into(p, path, current_parent) do return NIL_SOURCE
			}
		} else {
			switch peek {
			case '=':
				// SEED — already applied in pass_1, just consume the value.
				p.pos += 1
				p.col += 1
				_, _ = parse_number(p)
			case '(':
				if current_parent == NIL_SOURCE {
					parse_error(p, "%s(...) appears before any top-level definition", name)
					return NIL_SOURCE
				}
				if name == "note" {
					if !parse_note_call(p, current_parent) do return NIL_SOURCE
				} else {
					if !parse_ref_call(p, name, current_parent) do return NIL_SOURCE
				}
			case:
				parse_error(p, "expected ':', '=' or '(' after %s", name)
				return NIL_SOURCE
			}
		}
	}
	return last
}


// Read `path` from disk, parse it as a Standard MIDI File, and add a
// Note source-event to `parent` for each parsed note. Path is resolved
// relative to the current working directory. On any failure (read or
// MIDI parse), emits a parse_error and returns false; the caller bails
// out of pass_2 and parse_source returns ok=false.
@(private)
load_midi_into :: proc(p: ^Parser, path: string, parent: Source_Index) -> bool {
	bytes, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		parse_error(p, "could not read midi file %q: %v", path, read_err)
		return false
	}
	defer delete(bytes)

	notes, ok := parse_midi_file(bytes)
	if !ok {
		parse_error(p, "could not parse midi file %q", path)
		return false
	}
	defer delete(notes)

	for n in notes {
		add_source_event(
			&p.source,
			parent,
			Source_Event {
				beat = n.start_beat,
				chance = NOTE_DEFAULT_CHANCE,
				kind = Note{number = n.number, velocity = n.velocity, duration = n.duration},
			},
		)
	}
	return true
}


// Skip a balanced `(...)` block starting at the current `(`.
@(private)
skip_call_args :: proc(p: ^Parser) -> bool {
	if p.pos >= len(p.src) || p.src[p.pos] != '(' {
		parse_error(p, "expected '('")
		return false
	}
	p.pos += 1
	p.col += 1
	depth := 1
	for p.pos < len(p.src) && depth > 0 {
		switch p.src[p.pos] {
		case '(':
			depth += 1
			p.pos += 1
			p.col += 1
		case ')':
			depth -= 1
			p.pos += 1
			p.col += 1
		case '\n':
			p.pos += 1
			p.line += 1
			p.col = 1
		case '#':
			for p.pos < len(p.src) && p.src[p.pos] != '\n' {
				p.pos += 1
				p.col += 1
			}
		case:
			p.pos += 1
			p.col += 1
		}
	}
	if depth != 0 {
		parse_error(p, "unterminated '('")
		return false
	}
	return true
}


// IDENT [kwarg=value]* :  — kwargs that customize the def's Source_Timeline.
// Stops at the first `:`. The caller consumes the colon.
@(private)
parse_def_kwargs :: proc(p: ^Parser, def_idx: Source_Index) -> bool {
	for {
		skip_ws(p)
		if p.pos >= len(p.src) {
			parse_error(p, "unexpected end of file in definition header")
			return false
		}
		if p.src[p.pos] == ':' do break

		arg_name, ok := parse_ident(p)
		if !ok {
			parse_error(p, "expected argument name or ':'")
			return false
		}
		if !expect(p, '=') do return false

		ev := source_get(&p.source, def_idx)
		t := &ev.kind.(Source_Timeline)

		switch arg_name {
		case "chan":
			v, vok := parse_number(p)
			if !vok {parse_error(p, "expected channel"); return false}
			ch := i32(v)
			if ch < 1 || ch > 16 {
				parse_error(p, "channel must be 1..16, got %d", ch)
				return false
			}
			t.channel = ch - 1
		case:
			parse_error(p, "unknown definition argument: %s", arg_name)
			return false
		}
	}
	return true
}


// NAME( TIME [trans=T] [rate=R] [chance=C] ).
// `name` has already been consumed; we're sitting on the `(`.
// Channel comes from the target def; wrap in another def if you want
// per-instance channels.
@(private)
parse_ref_call :: proc(p: ^Parser, name: string, parent: Source_Index) -> bool {
	target, exists := p.names.by_name[name]
	if !exists {
		parse_error(p, "undefined reference: %s", name)
		return false
	}

	if !expect(p, '(') do return false
	beat, ok_b := parse_number(p)
	if !ok_b {parse_error(p, "expected time"); return false}

	target_timeline := source_get(&p.source, target).kind.(Source_Timeline)

	trans: i32 = 0
	rate: f32 = 1
	chance: i32 = 100
	chan: i32 = target_timeline.channel
	free: bool = false
	for {
		skip_ws(p)
		if p.pos >= len(p.src) {
			parse_error(p, "unterminated reference")
			return false
		}
		if p.src[p.pos] == ')' do break

		arg_name, ok_a := parse_ident(p)
		if !ok_a {parse_error(p, "expected argument name or ')'"); return false}

		skip_ws(p)
		has_value := p.pos < len(p.src) && p.src[p.pos] == '='
		if has_value {
			p.pos += 1
			p.col += 1
		}

		switch arg_name {
		case "trans":
			if !has_value {parse_error(p, "trans requires '=value'"); return false}
			v, ok := parse_number(p)
			if !ok {parse_error(p, "expected transposition"); return false}
			trans = i32(v)
		case "rate":
			if !has_value {parse_error(p, "rate requires '=value'"); return false}
			v, ok := parse_number(p)
			if !ok {parse_error(p, "expected rate"); return false}
			rate = v
		case "chance":
			if !has_value {parse_error(p, "chance requires '=value'"); return false}
			c, ok := parse_number(p)
			if !ok {parse_error(p, "expected chance"); return false}
			chance = i32(c)
		case "free":
			if has_value {
				val, ok := parse_ident(p)
				if !ok {parse_error(p, "expected true or false"); return false}
				switch val {
				case "true":
					free = true
				case "false":
					free = false
				case:
					parse_error(p, "free expects true or false, got %s", val)
					return false
				}
			} else {
				free = true
			}
		case:
			parse_error(p, "unknown reference argument: %s", arg_name)
			return false
		}
	}
	if !expect(p, ')') do return false

	// Stash the target's index in `first`. It gets rewritten to the
	// target's actual children chain head by resolve_references after
	// every top-level body has been parsed.
	ref_idx := add_source_event(
		&p.source,
		parent,
		Source_Event {
			beat = beat,
			chance = chance,
			kind = Source_Timeline {
				first = target,
				channel = chan,
				transposition = trans,
				rate = rate,
				free = free,
			},
		},
	)
	if ref_idx != NIL_SOURCE {
		// Refs don't have a name of their own; record the target's
		// name so the debug view can label e.g. `BASS(0)` as "BASS".
		p.names.lookup[ref_idx], _ = strings.clone(
			name,
			mem.arena_allocator(&p.names.arena),
		)
	}
	return true
}


NOTE_DEFAULT_VELOCITY :: 100
NOTE_DEFAULT_DURATION :: 1.0
NOTE_DEFAULT_CHANCE :: 100

// note( TIME PITCH [vel=V] [dur=D] [chance=C] )
@(private)
parse_note_call :: proc(p: ^Parser, parent: Source_Index) -> bool {
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

	add_source_event(
		&p.source,
		parent,
		Source_Event {
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
		case '#':
			for p.pos < len(p.src) && p.src[p.pos] != '\n' {
				p.pos += 1
				p.col += 1
			}
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

// Read a `"..."` literal. No escape sequences for now.
@(private)
parse_string_literal :: proc(p: ^Parser) -> (string, bool) {
	skip_ws(p)
	if p.pos >= len(p.src) || p.src[p.pos] != '"' do return "", false
	p.pos += 1
	p.col += 1
	start := p.pos
	for p.pos < len(p.src) && p.src[p.pos] != '"' {
		if p.src[p.pos] == '\n' {
			p.line += 1
			p.col = 1
		} else {
			p.col += 1
		}
		p.pos += 1
	}
	if p.pos >= len(p.src) {
		parse_error(p, "unterminated string literal")
		return "", false
	}
	s := p.src[start:p.pos]
	p.pos += 1
	p.col += 1
	return s, true
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

@(private)
is_alpha :: proc(c: u8) -> bool {
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
}

@(private)
is_ident_start :: proc(c: u8) -> bool {
	return is_alpha(c) || c == '_'
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
