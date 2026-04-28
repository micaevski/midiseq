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
	src:         string,
	pos:         int,
	line:        int,
	col:         int,
	scratch:     mem.Arena,
	scratch_buf: []byte,
	last_error:  string,
}


PARSE_SCRATCH_BYTES :: 4 * 1024 * 1024


// The implicit global-scope timeline. Reserved as a label name; defining
// a header with this name is a parse error. Lives in `names` so
// adapt_to_source can remap it across reloads via the existing
// name-keyed path.
ROOT_NAME :: "__ROOT__"


make_parser :: proc(pool_bytes: int = DEFAULT_POOL_BYTES) -> Parser {
	capacity := pool_bytes / size_of(Source_Event)
	p := Parser{}
	p.source = make_source_store(capacity)
	p.names = make_names()
	p.scratch_buf = make([]byte, PARSE_SCRATCH_BYTES)
	mem.arena_init(&p.scratch, p.scratch_buf)
	return p
}

destroy_parser :: proc(p: ^Parser) {
	delete(p.source)
	destroy_names(&p.names)
	delete(p.scratch_buf)
	p^ = {}
}


parse_file :: proc(parser: ^Parser, path: string) -> (root: Source_Index, ok: bool) {
	parser.last_error = ""
	mem.arena_free_all(&parser.scratch)
	context.allocator = mem.arena_allocator(&parser.scratch)

	bytes, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		parser.last_error = fmt.aprintf("could not read %s: %v", path, err)
		fmt.eprintln(parser.last_error)
		return NIL_SOURCE, false
	}

	return parse_source(parser, string(bytes))
}


// Parse `src` into the parser's own buffers. On success, the caller
// swaps `parser.source`/`parser.names` into the live sequencer and
// uses the returned root index.
//
// Grammar (line-oriented; one event per line):
//
//   IDENT [chan=N] :             // header — opens a definition
//   NOTE [time] [vel=V] [dur=D] [chance=C]    // note event (e.g. C4 0 dur=2)
//   IDENT[!] [time] [trans=T] [rate=R] [chance=C]  // ref event (`!` = free)
//   "path" [time]                // load notes from a MIDI file at `time`
//
//   SEED = N                     // optional directive
//   # ...                        // line comment
//
// The file's global scope is the implicit root timeline (named
// `__ROOT__`); top-level event/ref lines become children of root and
// fire as the root cursor reaches them. A header opens a definition
// whose body is the following event lines, terminated by a blank line
// (or another header at root scope). Nested definitions are not
// allowed. To play a defined timeline, write its name as a ref at
// global scope. `time` defaults to 0. Note names (C4, F#3, Ab-1, ...)
// are reserved and cannot be used as label names.
parse_source :: proc(parser: ^Parser, src: string) -> (root: Source_Index, ok: bool) {
	context.allocator = mem.arena_allocator(&parser.scratch)

	// Wipe any leftovers from a previous parse (or from buffers we
	// just received via swap on a previous successful reparse).
	source_store_reset(&parser.source)
	names_reset(&parser.names)
	parser.rng_state = 0

	parser.src = src
	parser.pos = 0
	parser.line = 1
	parser.col = 1

	// Allocate the implicit root timeline up front. Both passes treat
	// it as the parent of any line that isn't inside an open definition.
	root = source_alloc(&parser.source)
	if root == NIL_SOURCE {
		parse_error(parser, "source storage full")
		return NIL_SOURCE, false
	}
	root_event := source_get(&parser.source, root)
	root_event.chance = 100
	root_event.kind = Source_Timeline{rate = 1, channel = -1}
	root_name, _ := strings.clone(ROOT_NAME, mem.arena_allocator(&parser.names.arena))
	parser.names.lookup[root] = root_name
	parser.names.by_name[root_name] = root

	// Pass 1: discover every `IDENT:` header and reserve a Timeline
	// event for it.
	if !pass_1(parser) do return NIL_SOURCE, false

	// Pass 2: walk the source again. Each `IDENT:` rebinds the current
	// parent; each event line is added to that parent. A blank line
	// pops back to root scope.
	parser.pos = 0
	parser.line = 1
	parser.col = 1
	if !pass_2(parser, root) do return NIL_SOURCE, false

	// Pass 3: every top-level body is populated now, so we can rewrite
	// each reference's stashed target-index into the target's actual
	// children chain head.
	resolve_references(parser)

	return root, true
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


// Pass 1: walk the source linearly. Each header (`IDENT [chan=N]:`)
// reserves a Source_Timeline slot in the source store and registers
// the label name; events on other lines are skipped (parsed in pass_2).
// `SEED = N` is consumed here.
@(private)
pass_1 :: proc(p: ^Parser) -> bool {
	for {
		skip_ws(p)
		if p.pos >= len(p.src) do break

		c := p.src[p.pos]

		// String-literal event ("path" [time]) — owned by pass_2.
		if c == '"' {
			skip_to_line_end(p)
			continue
		}

		// Header lines have a `:` somewhere on them; everything else
		// is an event line (or a SEED directive).
		if peek_line_has_colon(p) {
			name, ok := parse_ident(p)
			if !ok {parse_error(p, "expected identifier"); return false}
			if name == "SEED" {
				parse_error(p, "SEED uses '=', not ':'")
				return false
			}
			if name == ROOT_NAME {
				parse_error(p, "%q is reserved as the implicit root name", ROOT_NAME)
				return false
			}
			if is_note_name_string(name) || is_degree_note_name_string(name) {
				parse_error(p, "note name %s cannot be used as a label", name)
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
			if !parse_def_kwargs(p, idx) do return false
			if !expect(p, ':') do return false
			continue
		}

		// SEED = N
		if is_ident_start(c) {
			save_pos := p.pos
			save_col := p.col
			save_line := p.line
			name, ok := parse_ident(p)
			if !ok {parse_error(p, "expected identifier"); return false}
			if name == "SEED" {
				skip_inline_ws(p)
				if p.pos < len(p.src) && p.src[p.pos] == '=' {
					p.pos += 1
					p.col += 1
					n, n_ok := parse_number(p)
					if !n_ok {parse_error(p, "expected SEED value"); return false}
					p.rng_state = u32(n)
					skip_to_line_end(p)
					continue
				}
			}
			// Not SEED — restore and treat as an event line in pass_2.
			p.pos = save_pos
			p.col = save_col
			p.line = save_line
			skip_to_line_end(p)
			continue
		}

		// Anything else (number, operator, etc.) at line start is an
		// event-shaped line that pass_2 will validate.
		skip_to_line_end(p)
	}
	return true
}


// Pass 2: walk the source again. Each header at root scope rebinds the
// current parent; each event line is parsed and added to the current
// parent. A blank line pops back to root scope. Headers inside an open
// definition are an error (no nesting). Refs stash the target's index
// in their `first` field — `resolve_references` rewrites it into the
// target's children-chain head once all bodies are populated.
@(private)
pass_2 :: proc(p: ^Parser, root: Source_Index) -> bool {
	current_parent := root

	for {
		// A blank line (two or more newlines spanning any combination
		// of whitespace/comments) closes the open definition.
		if skip_ws_track_blank(p) do current_parent = root
		if p.pos >= len(p.src) do break

		c := p.src[p.pos]

		// String-literal event: "path" [time]
		if c == '"' {
			path, ok_s := parse_string_literal(p)
			if !ok_s do return false
			skip_inline_ws(p)
			time: f32 = 0
			if !at_line_end(p) {
				v, ok := parse_number(p)
				if !ok {parse_error(p, "expected time after path"); return false}
				time = v - 1
			}
			if !expect_line_end(p) do return false
			if !load_midi_into(p, path, current_parent, time) do return false
			continue
		}

		// Header line.
		if peek_line_has_colon(p) {
			name, ok := parse_ident(p)
			if !ok {parse_error(p, "expected identifier"); return false}
			if current_parent != root {
				parse_error(
					p,
					"nested definition '%s'; close the enclosing definition with a blank line first",
					name,
				)
				return false
			}
			idx := p.names.by_name[name]
			// Names from p.src are slices into the caller-owned source
			// string and disappear once parsing is done; clone into the
			// parser's names arena so they survive the swap into the
			// sequencer.
			p.names.lookup[idx], _ = strings.clone(
				name,
				mem.arena_allocator(&p.names.arena),
			)
			if !parse_def_kwargs(p, idx) do return false
			if !expect(p, ':') do return false
			if !expect_line_end(p) do return false
			current_parent = idx
			continue
		}

		// Event or SEED. Notes start with a note letter, and might
		// otherwise look like an ident; try the note pattern first.
		if num, is_note := try_parse_note_name(p); is_note {
			if !parse_note_event(p, current_parent, num) do return false
			continue
		}
		if deg, oct, is_deg := try_parse_degree_note(p); is_deg {
			if !parse_degree_note_event(p, current_parent, deg, oct) do return false
			continue
		}

		if !is_ident_start(c) {
			parse_error(p, "unexpected character %c", rune(c))
			return false
		}

		name, ok := parse_ident(p)
		if !ok {parse_error(p, "expected identifier"); return false}

		if name == "SEED" {
			skip_inline_ws(p)
			if p.pos < len(p.src) && p.src[p.pos] == '=' {
				p.pos += 1
				p.col += 1
				_, _ = parse_number(p)
				skip_to_line_end(p)
				continue
			}
			parse_error(p, "SEED requires '= N'")
			return false
		}

		// `NAME!` is shorthand for `NAME free=true`.
		auto_free := false
		if p.pos < len(p.src) && p.src[p.pos] == '!' {
			p.pos += 1
			p.col += 1
			auto_free = true
		}

		if !parse_ref_event(p, name, current_parent, auto_free) do return false
	}
	return true
}

@(private)
expect_line_end :: proc(p: ^Parser) -> bool {
	skip_inline_ws(p)
	if p.pos < len(p.src) && p.src[p.pos] != '\n' {
		parse_error(p, "unexpected trailing content")
		return false
	}
	return true
}


// Read `path` from disk, parse it as a Standard MIDI File, and add a
// Note source-event to `parent` for each parsed note (offset by `time`).
// Path is resolved relative to the current working directory. On any
// failure (read or MIDI parse), emits a parse_error and returns false;
// the caller bails out of pass_2 and parse_source returns ok=false.
@(private)
load_midi_into :: proc(p: ^Parser, path: string, parent: Source_Index, time: f32) -> bool {
	bytes, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		parse_error(p, "could not read midi file %q: %v", path, read_err)
		return false
	}

	notes, ok := parse_midi_file(bytes)
	if !ok {
		parse_error(p, "could not parse midi file %q", path)
		return false
	}

	for n in notes {
		add_source_event(
			&p.source,
			parent,
			Source_Event {
				beat = quantize(n.start_beat + time),
				chance = NOTE_DEFAULT_CHANCE,
				kind = Note {
					number = Note_Number{pitch = n.number, is_degree = false},
					velocity = n.velocity,
					duration = max(quantize(n.duration), BEAT_QUANTUM),
				},
			},
		)
	}
	return true
}


// IDENT [kwarg=value]* :  — kwargs that customize the def's Source_Timeline.
// Stops at the first `:`. The caller consumes the colon.
@(private)
parse_def_kwargs :: proc(p: ^Parser, def_idx: Source_Index) -> bool {
	for {
		skip_inline_ws(p)
		if p.pos >= len(p.src) || p.src[p.pos] == '\n' {
			parse_error(p, "header missing ':'")
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


// IDENT[!] [time] [trans=T] [rate=R] [chance=C]
// `name` has already been consumed; we're sitting after it (and any `!`)
// on the line. `auto_free` reflects whether `!` was present.
// Channel comes from the target def; wrap in another def if you want
// per-instance channels.
@(private)
parse_ref_event :: proc(p: ^Parser, name: string, parent: Source_Index, auto_free: bool) -> bool {
	target, exists := p.names.by_name[name]
	if !exists {
		parse_error(p, "undefined reference: %s", name)
		return false
	}

	target_timeline := source_get(&p.source, target).kind.(Source_Timeline)

	skip_inline_ws(p)
	beat: f32 = 0
	if !at_line_end(p) && !is_kwarg_start(p) {
		v, ok := parse_number(p)
		if !ok {parse_error(p, "expected time or kwarg"); return false}
		beat = v - 1
	}

	trans: Transposition
	rate: f32 = 1
	chance: i32 = 100
	chan: i32 = target_timeline.channel
	free: bool = auto_free
	scale: Scale
	for {
		if at_line_end(p) do break

		arg_name, ok_a := parse_ident(p)
		if !ok_a {parse_error(p, "expected argument name"); return false}

		skip_inline_ws(p)
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
			// `trans=2d` writes scale degrees; `trans=2` writes semitones.
			if p.pos < len(p.src) && p.src[p.pos] == 'd' {
				p.pos += 1
				p.col += 1
				trans.degrees = i16(v)
			} else {
				trans.semitones = i16(v)
			}
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
		case "scale":
			if !has_value {parse_error(p, "scale requires '=value'"); return false}
			tok, ok := parse_scale_token(p)
			if !ok {parse_error(p, "expected scale name"); return false}
			s, ok2 := parse_scale_name(tok)
			if !ok2 {parse_error(p, "invalid scale name: %s (%s)", tok, SCALE_NAME_HELP); return false}
			scale = s
		case:
			parse_error(p, "unknown reference argument: %s", arg_name)
			return false
		}
	}

	// Stash the target's index in `first`. It gets rewritten to the
	// target's actual children chain head by resolve_references after
	// every top-level body has been parsed.
	ref_idx := add_source_event(
		&p.source,
		parent,
		Source_Event {
			beat = quantize(beat),
			chance = chance,
			kind = Source_Timeline {
				first = target,
				channel = chan,
				transposition = trans,
				rate = rate,
				free = free,
				scale = scale,
			},
		},
	)
	if ref_idx != NIL_SOURCE {
		// Refs don't have a name of their own; record the target's
		// name so the debug view can label it.
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

// NOTE [time] [vel=V] [dur=D] [chance=C]
// The note name has already been consumed by try_parse_note_name;
// `pitch` is the resolved MIDI number.
@(private)
parse_note_event :: proc(p: ^Parser, parent: Source_Index, pitch: i32) -> bool {
	skip_inline_ws(p)
	beat: f32 = 0
	if !at_line_end(p) && !is_kwarg_start(p) {
		v, ok := parse_number(p)
		if !ok {parse_error(p, "expected time or kwarg"); return false}
		beat = v - 1
	}

	vel: i32 = NOTE_DEFAULT_VELOCITY
	dur: f32 = NOTE_DEFAULT_DURATION
	chance: i32 = NOTE_DEFAULT_CHANCE

	for {
		if at_line_end(p) do break

		arg_name, ok_a := parse_ident(p)
		if !ok_a {parse_error(p, "expected argument name"); return false}
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

	add_source_event(
		&p.source,
		parent,
		Source_Event {
			beat = quantize(beat),
			chance = chance,
			kind = Note {
				number = Note_Number{pitch = pitch, is_degree = false},
				velocity = vel,
				duration = max(quantize(dur), BEAT_QUANTUM),
			},
		},
	)
	return true
}


@(private)
parse_degree_note_event :: proc(
	p: ^Parser,
	parent: Source_Index,
	degree, octave: i32,
) -> bool {
	skip_inline_ws(p)
	beat: f32 = 0
	if !at_line_end(p) && !is_kwarg_start(p) {
		v, ok := parse_number(p)
		if !ok {parse_error(p, "expected time or kwarg"); return false}
		beat = v - 1
	}

	vel: i32 = NOTE_DEFAULT_VELOCITY
	dur: f32 = NOTE_DEFAULT_DURATION
	chance: i32 = NOTE_DEFAULT_CHANCE

	for {
		if at_line_end(p) do break

		arg_name, ok_a := parse_ident(p)
		if !ok_a {parse_error(p, "expected argument name"); return false}
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

	add_source_event(
		&p.source,
		parent,
		Source_Event {
			beat = quantize(beat),
			chance = chance,
			kind = Note {
				number = Note_Number{pitch = degree, octave = octave, is_degree = true},
				velocity = vel,
				duration = max(quantize(dur), BEAT_QUANTUM),
			},
		},
	)
	return true
}

// `name=...` form: returns true if the next token on the current line
// is an ident immediately followed by `=`.
@(private)
is_kwarg_start :: proc(p: ^Parser) -> bool {
	if p.pos >= len(p.src) do return false
	if !is_ident_start(p.src[p.pos]) do return false
	pos := p.pos + 1
	for pos < len(p.src) {
		c := p.src[pos]
		if is_alpha(c) || is_digit(c) || c == '_' {
			pos += 1
		} else {
			break
		}
	}
	for pos < len(p.src) && (p.src[pos] == ' ' || p.src[pos] == '\t') do pos += 1
	return pos < len(p.src) && p.src[pos] == '='
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

// Like skip_ws, but reports whether a blank line was crossed (>= 2
// newlines, optionally interleaved with horizontal whitespace and
// comments). Pass_2 uses this to close a definition.
@(private)
skip_ws_track_blank :: proc(p: ^Parser) -> (crossed_blank: bool) {
	newlines := 0
	for p.pos < len(p.src) {
		switch p.src[p.pos] {
		case ' ', '\t', '\r', ',':
			p.pos += 1
			p.col += 1
		case '\n':
			p.pos += 1
			p.line += 1
			p.col = 1
			newlines += 1
		case '#':
			for p.pos < len(p.src) && p.src[p.pos] != '\n' {
				p.pos += 1
				p.col += 1
			}
		case:
			return newlines >= 2
		}
	}
	return newlines >= 2
}

// Like skip_ws but stops at newlines.
@(private)
skip_inline_ws :: proc(p: ^Parser) {
	for p.pos < len(p.src) {
		switch p.src[p.pos] {
		case ' ', '\t', '\r', ',':
			p.pos += 1
			p.col += 1
		case '#':
			for p.pos < len(p.src) && p.src[p.pos] != '\n' {
				p.pos += 1
				p.col += 1
			}
			return
		case:
			return
		}
	}
}

@(private)
at_line_end :: proc(p: ^Parser) -> bool {
	skip_inline_ws(p)
	return p.pos >= len(p.src) || p.src[p.pos] == '\n'
}

@(private)
skip_to_line_end :: proc(p: ^Parser) {
	for p.pos < len(p.src) && p.src[p.pos] != '\n' {
		p.pos += 1
		p.col += 1
	}
}

// Look ahead from the current position to see if the rest of the
// current line contains a `:` outside of any string literal.
// Used to disambiguate a header line from an event line.
@(private)
peek_line_has_colon :: proc(p: ^Parser) -> bool {
	pos := p.pos
	in_string := false
	for pos < len(p.src) {
		c := p.src[pos]
		if c == '\n' do return false
		if c == '#' && !in_string do return false
		if c == '"' do in_string = !in_string
		if c == ':' && !in_string do return true
		pos += 1
	}
	return false
}

// Return true if `s` matches the note-name pattern (e.g. "C4", "Bb3").
// `#` cannot appear in a parsed ident, so only the flat form needs
// checking here.
@(private)
is_note_name_string :: proc(s: string) -> bool {
	if len(s) == 0 do return false
	if _, ok := note_letter_base(s[0]); !ok do return false
	pos := 1
	if pos < len(s) && s[pos] == 'b' do pos += 1
	if pos < len(s) && s[pos] == '-' do pos += 1
	if pos >= len(s) || !is_digit(s[pos]) do return false
	for pos < len(s) && is_digit(s[pos]) do pos += 1
	return pos == len(s)
}


@(private)
is_degree_note_name_string :: proc(s: string) -> bool {
	if len(s) < 2 do return false
	if s[0] != 'P' && s[0] != 'p' do return false
	pos := 1
	if !is_digit(s[pos]) do return false
	for pos < len(s) && is_digit(s[pos]) do pos += 1
	if pos == len(s) do return true
	if s[pos] != 'O' && s[pos] != 'o' do return false
	pos += 1
	if pos >= len(s) || !is_digit(s[pos]) do return false
	for pos < len(s) && is_digit(s[pos]) do pos += 1
	return pos == len(s)
}

// Try to consume a note name at the current position. On success
// advances `p` and returns the MIDI number; on failure restores `p`
// and returns false (no error emitted).
@(private)
try_parse_degree_note :: proc(p: ^Parser) -> (degree, octave: i32, ok: bool) {
	if p.pos >= len(p.src) do return 0, 0, false
	c := p.src[p.pos]
	if c != 'P' && c != 'p' do return 0, 0, false

	save_pos := p.pos
	save_col := p.col

	p.pos += 1
	p.col += 1

	if p.pos >= len(p.src) || !is_digit(p.src[p.pos]) {
		p.pos = save_pos
		p.col = save_col
		return 0, 0, false
	}

	deg: i32 = 0
	for p.pos < len(p.src) && is_digit(p.src[p.pos]) {
		deg = deg * 10 + i32(p.src[p.pos] - '0')
		p.pos += 1
		p.col += 1
	}

	oct: i32 = 3
	if p.pos < len(p.src) && (p.src[p.pos] == 'O' || p.src[p.pos] == 'o') {
		p.pos += 1
		p.col += 1
		if p.pos >= len(p.src) || !is_digit(p.src[p.pos]) {
			p.pos = save_pos
			p.col = save_col
			return 0, 0, false
		}
		oct = 0
		for p.pos < len(p.src) && is_digit(p.src[p.pos]) {
			oct = oct * 10 + i32(p.src[p.pos] - '0')
			p.pos += 1
			p.col += 1
		}
	}

	if p.pos < len(p.src) {
		c2 := p.src[p.pos]
		if is_alpha(c2) || c2 == '_' || is_digit(c2) {
			p.pos = save_pos
			p.col = save_col
			return 0, 0, false
		}
	}

	return deg, oct, true
}


@(private)
try_parse_note_name :: proc(p: ^Parser) -> (i32, bool) {
	if p.pos >= len(p.src) do return 0, false
	base, ok := note_letter_base(p.src[p.pos])
	if !ok do return 0, false

	save_pos := p.pos
	save_col := p.col

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
		p.pos = save_pos
		p.col = save_col
		return 0, false
	}

	octave: i32 = 0
	for p.pos < len(p.src) && is_digit(p.src[p.pos]) {
		octave = octave * 10 + i32(p.src[p.pos] - '0')
		p.pos += 1
		p.col += 1
	}
	octave *= octave_sign

	if p.pos < len(p.src) {
		c2 := p.src[p.pos]
		if is_alpha(c2) || c2 == '_' {
			p.pos = save_pos
			p.col = save_col
			return 0, false
		}
	}

	return (octave + 1) * 12 + base, true
}

@(private)
expect :: proc(p: ^Parser, ch: u8) -> bool {
	skip_inline_ws(p)
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
	skip_inline_ws(p)
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


// Read a contiguous run of alpha characters and `#`. Used for scale
// names ("C#M", "BbPm"); plain `parse_ident` rejects `#`.
@(private)
parse_scale_token :: proc(p: ^Parser) -> (string, bool) {
	skip_inline_ws(p)
	start := p.pos
	for p.pos < len(p.src) {
		c := p.src[p.pos]
		if is_alpha(c) || c == '#' {
			p.pos += 1
			p.col += 1
		} else {
			break
		}
	}
	if p.pos == start do return "", false
	return p.src[start:p.pos], true
}

@(private)
parse_ident :: proc(p: ^Parser) -> (string, bool) {
	skip_inline_ws(p)
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
	skip_inline_ws(p)
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
	body := fmt.aprintf(format, ..args)
	p.last_error = fmt.aprintf("parse error at %d:%d: %s", p.line, p.col, body)
	fmt.eprintln(p.last_error)
}
