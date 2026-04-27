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
// Grammar (line-oriented; one event per line):
//
//   IDENT [chan=N] :             // header — begins a top-level definition
//   NOTE [time] [vel=V] [dur=D] [chance=C]    // note event (e.g. C4 0 dur=2)
//   IDENT[!] [time] [trans=T] [rate=R] [chance=C]  // ref event (`!` = free)
//   "path" [time]                // load notes from a MIDI file at `time`
//
//   SEED = N                     // optional directive
//   @play                        // mark the next definition as a play target
//   # ...                        // line comment
//
// `time` defaults to 0. Note names (C4, F#3, Ab-1, ...) are reserved
// and cannot be used as label names.
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


// Pass 1: walk the source linearly. Each header (`IDENT [chan=N]:`)
// reserves a Source_Timeline slot in the source store and registers
// the label name; events on other lines are skipped (parsed in pass_2).
// `SEED = N` is consumed here.
@(private)
pass_1 :: proc(p: ^Parser) -> bool {
	pending_play := false
	for {
		skip_ws(p)
		if p.pos >= len(p.src) do break

		c := p.src[p.pos]

		// `@play` line — flag the next IDENT: header.
		if c == '@' {
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
			if is_note_name_string(name) {
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
			if pending_play {
				append(&p.play_marked, idx)
				pending_play = false
			}
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
	if pending_play {
		parse_error(p, "@play with no following label")
		return false
	}
	return true
}


// Pass 2: walk the source again. Each header rebinds the current
// parent; each event line is parsed and added to that parent. Refs
// stash the target's index in their `first` field — `resolve_references`
// rewrites it into the target's children-chain head once all bodies are
// populated.
@(private)
pass_2 :: proc(p: ^Parser) -> Source_Index {
	last := NIL_SOURCE
	current_parent := NIL_SOURCE

	for {
		skip_ws(p)
		if p.pos >= len(p.src) do break

		c := p.src[p.pos]

		// `@anno` lines — consumed for their effect in pass_1.
		if c == '@' {
			p.pos += 1
			p.col += 1
			_, _ = parse_ident(p)
			continue
		}

		// String-literal event: "path" [time]
		if c == '"' {
			if current_parent == NIL_SOURCE {
				parse_error(p, "file event appears before any top-level definition")
				return NIL_SOURCE
			}
			path, ok_s := parse_string_literal(p)
			if !ok_s do return NIL_SOURCE
			skip_inline_ws(p)
			time: f32 = 0
			if !at_line_end(p) {
				v, ok := parse_number(p)
				if !ok {parse_error(p, "expected time after path"); return NIL_SOURCE}
				time = v
			}
			if !expect_line_end(p) do return NIL_SOURCE
			if !load_midi_into(p, path, current_parent, time) do return NIL_SOURCE
			continue
		}

		// Header line.
		if peek_line_has_colon(p) {
			name, ok := parse_ident(p)
			if !ok {parse_error(p, "expected identifier"); return NIL_SOURCE}
			idx := p.names.by_name[name]
			// Names from p.src are slices into the caller-owned source
			// string and disappear once parsing is done; clone into the
			// parser's names arena so they survive the swap into the
			// sequencer.
			p.names.lookup[idx], _ = strings.clone(
				name,
				mem.arena_allocator(&p.names.arena),
			)
			if !parse_def_kwargs(p, idx) do return NIL_SOURCE
			if !expect(p, ':') do return NIL_SOURCE
			if !expect_line_end(p) do return NIL_SOURCE
			current_parent = idx
			last = idx
			continue
		}

		// Event or SEED. Notes start with a note letter, and might
		// otherwise look like an ident; try the note pattern first.
		if num, is_note := try_parse_note_name(p); is_note {
			if current_parent == NIL_SOURCE {
				parse_error(p, "event before any top-level definition")
				return NIL_SOURCE
			}
			if !parse_note_event(p, current_parent, num) do return NIL_SOURCE
			continue
		}

		if !is_ident_start(c) {
			parse_error(p, "unexpected character %c", rune(c))
			return NIL_SOURCE
		}

		name, ok := parse_ident(p)
		if !ok {parse_error(p, "expected identifier"); return NIL_SOURCE}

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
			return NIL_SOURCE
		}

		// `NAME!` is shorthand for `NAME free=true`.
		auto_free := false
		if p.pos < len(p.src) && p.src[p.pos] == '!' {
			p.pos += 1
			p.col += 1
			auto_free = true
		}

		if current_parent == NIL_SOURCE {
			parse_error(p, "event before any top-level definition")
			return NIL_SOURCE
		}
		if !parse_ref_event(p, name, current_parent, auto_free) do return NIL_SOURCE
	}
	return last
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
				beat = quantize(n.start_beat + time),
				chance = NOTE_DEFAULT_CHANCE,
				kind = Note {
					number = n.number,
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
		beat = v
	}

	trans: i32 = 0
	rate: f32 = 1
	chance: i32 = 100
	chan: i32 = target_timeline.channel
	free: bool = auto_free
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
		beat = v
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
				number = pitch,
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
	upper := s[0]
	if upper >= 'a' && upper <= 'z' do upper -= 'a' - 'A'
	if !(upper >= 'A' && upper <= 'G') do return false
	pos := 1
	if pos < len(s) && s[pos] == 'b' do pos += 1
	if pos < len(s) && s[pos] == '-' do pos += 1
	if pos >= len(s) || !is_digit(s[pos]) do return false
	for pos < len(s) && is_digit(s[pos]) do pos += 1
	return pos == len(s)
}

// Try to consume a note name at the current position. On success
// advances `p` and returns the MIDI number; on failure restores `p`
// and returns false (no error emitted).
@(private)
try_parse_note_name :: proc(p: ^Parser) -> (i32, bool) {
	if p.pos >= len(p.src) do return 0, false
	c := p.src[p.pos]
	upper := c
	if upper >= 'a' && upper <= 'z' do upper -= 'a' - 'A'
	if !(upper >= 'A' && upper <= 'G') do return 0, false

	save_pos := p.pos
	save_col := p.col

	base: i32
	switch upper {
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
	fmt.eprintf("parse error at %d:%d: ", p.line, p.col)
	fmt.eprintfln(format, ..args)
}
