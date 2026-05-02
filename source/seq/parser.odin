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
	source:                 [dynamic]Source_Event,
	names:                  Names,
	seed:                   u64,
	src:                    string,
	pos:                    int,
	line:                   int,
	col:                    int,
	scratch:                mem.Arena,
	scratch_buf:            []byte,
	last_error:             string,
	macros:                 map[string]Macro_Def,
	macro_instances:        [dynamic]Source_Index,
	macro_instances_by_key: map[string]Source_Index,
	macro_depth:            int,
	pending_tails:          [dynamic]Pending_Tail,
	sub_chain_head:         ^Source_Index,
	sub_chain_tail:         ^Source_Index,
}


@(private)
Pending_Tail :: struct {
	parent: Source_Index,
	tail:   Source_Index,
}


// Macros are parse-time only: a definition captures its parameter
// names and the raw body text (a slice of `src`). On each invocation
// we textually substitute `$name` tokens and re-parse the result into
// a fresh anonymous `Source_Timeline` parented under the caller.
Macro_Def :: struct {
	params: []string,
	body:   string,
}


PARSE_SCRATCH_BYTES :: 4 * 1024 * 1024
MAX_MACRO_DEPTH :: 32
MAX_MACRO_PARAMS :: 16
MAX_MACRO_ARGS :: 16


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

	return parse_source_internal(parser, string(bytes))
}


// Parse `src` into the parser's own buffers. On success, the caller
// swaps `parser.source`/`parser.names` into the live sequencer and
// uses the returned root index.
//
// `src` is owned by the caller; it must outlive this call. Internal
// allocations (names, macro bookkeeping, source events) live in the
// parser's scratch arena, which is reset on entry.
//
// Grammar (line-oriented; one event per line):
//
//   IDENT :                                   // header — opens a definition
//   NOTE [time] [vel=V] [dur=D] [chance=C]    // note event (e.g. C4 0 dur=2)
//   IDENT[!] [time] [trans=T] [rate=R] [chance=C] [chan=N] [scale=S]  // ref
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
	mem.arena_free_all(&parser.scratch)
	context.allocator = mem.arena_allocator(&parser.scratch)
	return parse_source_internal(parser, src)
}


// Inner parser entry. Assumes scratch has already been reset and that
// `context.allocator` points at the scratch arena. `src` must outlive
// this call (it isn't copied).
@(private)
parse_source_internal :: proc(parser: ^Parser, src: string) -> (root: Source_Index, ok: bool) {
	// Wipe any leftovers from a previous parse (or from buffers we
	// just received via swap on a previous successful reparse).
	source_store_reset(&parser.source)
	names_reset(&parser.names)
	parser.seed = 0
	parser.macros = make(map[string]Macro_Def, 16)
	parser.macro_instances = make([dynamic]Source_Index, 0, 32)
	parser.macro_instances_by_key = make(map[string]Source_Index, 32)
	parser.macro_depth = 0
	parser.pending_tails = make([dynamic]Pending_Tail, 0, 8)

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
	root_event.kind = Source_Timeline{rate = 1}
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

	// Expose every macro instance under its memo key in the public
	// name map. `adapt_to_source` looks up runtime events by name; with
	// this in place a running macro-instance runtime survives a reparse
	// (gets remapped to the new instance with the same key) instead of
	// retiring and leaving a silent gap.
	for key, inst_idx in parser.macro_instances_by_key {
		cloned, _ := strings.clone(key, mem.arena_allocator(&parser.names.arena))
		parser.names.by_name[cloned] = inst_idx
	}

	return root, true
}


// Walk every timeline that owns a children chain (top-level
// definitions plus anonymous macro instances) and rewrite any
// children that are *refs*, replacing the target's event index with
// the target's children chain head. Macro instances themselves are
// children of their caller but they own a real chain — they're
// recognised via the `instance_set` lookup so we don't mistake them
// for refs. Forks redirect: when we hit one we also recurse through
// `else_first` so refs in the else-branch get resolved.
@(private)
resolve_references :: proc(p: ^Parser) {
	instance_set := make(map[Source_Index]bool, len(p.macro_instances))
	for idx in p.macro_instances do instance_set[idx] = true

	walk :: proc(p: ^Parser, parent_idx: Source_Index, instance_set: map[Source_Index]bool) {
		parent_event := source_get(&p.source, parent_idx)
		parent_timeline, ok := parent_event.kind.(Source_Timeline)
		if !ok do return
		visited := make(map[Source_Index]bool, 16, context.temp_allocator)
		defer delete(visited)
		walk_chain(p, parent_timeline.first, instance_set, &visited)
	}

	walk_chain :: proc(
		p: ^Parser,
		head: Source_Index,
		instance_set: map[Source_Index]bool,
		visited: ^map[Source_Index]bool,
	) {
		walker := head
		for walker != NIL_SOURCE && !visited[walker] {
			visited[walker] = true
			child := source_get(&p.source, walker)
			next := child.next
			if _, is_timeline := child.kind.(Source_Timeline); is_timeline {
				if !instance_set[walker] {
					ref_timeline := &child.kind.(Source_Timeline)
					target := ref_timeline.first
					ref_timeline.first =
						source_get(&p.source, target).kind.(Source_Timeline).first
				}
			} else if fork, is_fork := child.kind.(Source_Fork); is_fork {
				walk_chain(p, fork.else_first, instance_set, visited)
			}
			walker = next
		}
	}

	for _, top_index in p.names.by_name do walk(p, top_index, instance_set)
	for inst_idx in p.macro_instances do walk(p, inst_idx, instance_set)
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
		// is an event line (or a SEED directive). A header may be a
		// regular timeline (`NAME:`) or a macro definition (`NAME(...):`).
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
			if name == "if" || name == "else" || name == "end" {
				parse_error(p, "%q is reserved as an if-block keyword", name)
				return false
			}
			if is_note_name_string(name) || is_degree_note_name_string(name) {
				parse_error(p, "note name %s cannot be used as a label", name)
				return false
			}

			skip_inline_ws(p)
			if p.pos < len(p.src) && p.src[p.pos] == '(' {
				// Macro definition: NAME(p1, p2, ...): body
				p.pos += 1
				p.col += 1
				params, p_ok := parse_macro_param_list(p)
				if !p_ok do return false
				if !expect(p, ':') do return false
				if !expect_line_end(p) do return false
				if p.pos < len(p.src) && p.src[p.pos] == '\n' {
					p.pos += 1
					p.line += 1
					p.col = 1
				}
				body := capture_macro_body(p)
				p.macros[name] = Macro_Def {
					params = params,
					body   = body,
				}
				continue
			}

			idx := source_alloc(&p.source)
			if idx == NIL_SOURCE {
				parse_error(p, "source storage full")
				return false
			}
			top_event := source_get(&p.source, idx)
			top_event.chance = 100
			top_event.kind = Source_Timeline{rate = 1}
			p.names.by_name[name] = idx
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
					p.seed = u64(n)
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
				if v < 1 {parse_error(p, "time is 1-indexed; %.3g is invalid", v); return false}
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
			skip_inline_ws(p)
			if p.pos < len(p.src) && p.src[p.pos] == '(' {
				// Macro definition — already captured in pass_1. Skip
				// past `(...):` plus the body so pass_2 doesn't see the
				// body lines as events.
				skip_to_line_end(p)
				if p.pos < len(p.src) && p.src[p.pos] == '\n' {
					p.pos += 1
					p.line += 1
					p.col = 1
				}
				_ = capture_macro_body(p)
				continue
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
			if !expect(p, ':') do return false
			if !expect_line_end(p) do return false
			current_parent = idx
			continue
		}

		// Event or SEED. Notes start with a note letter, and might
		// otherwise look like an ident; try the note pattern first.
		if num, is_cc := try_parse_cc_number(p); is_cc {
			if !parse_cc_event(p, current_parent, num) do return false
			continue
		}
		if lo, hi, is_note := try_parse_note_range(p); is_note {
			if !parse_note_event(p, current_parent, lo, hi) do return false
			continue
		}
		if dlo, olo, dhi, ohi, is_deg := try_parse_degree_range(p); is_deg {
			if !parse_degree_note_event(p, current_parent, dlo, olo, dhi, ohi) do return false
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

		if name == "if" {
			if !parse_if_block(p, current_parent) do return false
			continue
		}
		if name == "else" || name == "end" {
			parse_error(p, "'%s' outside 'if' block", name)
			return false
		}

		// Macro invocation: NAME(args).
		if p.pos < len(p.src) && p.src[p.pos] == '(' {
			if !parse_macro_invocation(p, name, current_parent) do return false
			continue
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

// Parse the body of an anonymous macro instance: same line-shape as
// pass_2 but without header / SEED / blank-line-resets-parent
// handling. A blank line or EOF ends the body cleanly.
@(private)
pass_2_body :: proc(p: ^Parser, parent: Source_Index) -> bool {
	for {
		if skip_ws_track_blank(p) do return true
		if p.pos >= len(p.src) do return true

		c := p.src[p.pos]

		if c == '"' {
			path, ok_s := parse_string_literal(p)
			if !ok_s do return false
			skip_inline_ws(p)
			time: f32 = 0
			if !at_line_end(p) {
				v, ok := parse_number(p)
				if !ok {parse_error(p, "expected time after path"); return false}
				if v < 1 {parse_error(p, "time is 1-indexed; %.3g is invalid", v); return false}
				time = v - 1
			}
			if !expect_line_end(p) do return false
			if !load_midi_into(p, path, parent, time) do return false
			continue
		}

		if peek_line_has_colon(p) {
			parse_error(p, "macro body cannot contain a definition")
			return false
		}

		if num, is_cc := try_parse_cc_number(p); is_cc {
			if !parse_cc_event(p, parent, num) do return false
			continue
		}
		if lo, hi, is_note := try_parse_note_range(p); is_note {
			if !parse_note_event(p, parent, lo, hi) do return false
			continue
		}
		if dlo, olo, dhi, ohi, is_deg := try_parse_degree_range(p); is_deg {
			if !parse_degree_note_event(p, parent, dlo, olo, dhi, ohi) do return false
			continue
		}

		if !is_ident_start(c) {
			parse_error(p, "unexpected character %c", rune(c))
			return false
		}

		name, ok := parse_ident(p)
		if !ok {parse_error(p, "expected identifier"); return false}

		if name == "if" {
			if !parse_if_block(p, parent) do return false
			continue
		}
		if name == "else" || name == "end" {
			parse_error(p, "'%s' outside 'if' block", name)
			return false
		}

		if p.pos < len(p.src) && p.src[p.pos] == '(' {
			if !parse_macro_invocation(p, name, parent) do return false
			continue
		}

		auto_free := false
		if p.pos < len(p.src) && p.src[p.pos] == '!' {
			p.pos += 1
			p.col += 1
			auto_free = true
		}

		if !parse_ref_event(p, name, parent, auto_free) do return false
	}
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


// Wrapper around the chain-insertion helper. If a sub-chain is active
// (we're inside a fork's else-branch parse), the event lands there;
// otherwise it goes into `parent`'s main chain. Either way, branch
// tails registered against this parent get patched onto the new event
// so both branches of an upstream if-block converge on it.
@(private)
parser_add_event :: proc(
	p: ^Parser,
	parent: Source_Index,
	event: Source_Event,
) -> Source_Index {
	new_idx: Source_Index
	if p.sub_chain_head != nil && p.sub_chain_tail != nil {
		new_idx = add_source_event_chain(
			&p.source,
			p.sub_chain_head,
			p.sub_chain_tail,
			event,
		)
	} else {
		new_idx = add_source_event(&p.source, parent, event)
	}
	if new_idx == NIL_SOURCE do return NIL_SOURCE
	i := 0
	for i < len(p.pending_tails) {
		if p.pending_tails[i].parent == parent {
			tail_idx := p.pending_tails[i].tail
			source_get(&p.source, tail_idx).next = new_idx
			ordered_remove(&p.pending_tails, i)
		} else {
			i += 1
		}
	}
	return new_idx
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
		parser_add_event(
			p,
			parent,
			Source_Event {
				beat = quantize(n.start_beat + time),
				chance = NOTE_DEFAULT_CHANCE,
				kind = Source_Note {
					number = Note_Number{pitch1 = u8(n.number), pitch2 = u8(n.number), is_degree = false},
					velocity = n.velocity,
					duration = max(quantize(n.duration), BEAT_QUANTUM),
				},
			},
		)
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
	return parse_ref_event_with_target(p, target, name, parent, auto_free)
}


// Same as parse_ref_event but with an already-resolved target index.
// Used by macro invocations, which target an anonymous timeline that
// isn't in `names.by_name`. `display_name` is what the debug view
// shows next to the resulting ref.
@(private)
parse_ref_event_with_target :: proc(
	p: ^Parser,
	target: Source_Index,
	display_name: string,
	parent: Source_Index,
	auto_free: bool,
) -> bool {
	skip_inline_ws(p)
	beat: f32 = 0
	if !at_line_end(p) && !is_kwarg_start(p) {
		v, ok := parse_number(p)
		if !ok {parse_error(p, "expected time or kwarg"); return false}
		if v < 1 {parse_error(p, "time is 1-indexed; %.3g is invalid", v); return false}
		beat = v - 1
	}

	trans: Transposition
	rate: f32 = 1
	vel: i32 = 0
	chance: i32 = 100
	chan: Maybe(u8)
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
			if v <= 0 {parse_error(p, "rate must be positive, got %.3g", v); return false}
			rate = v
		case "vel":
			if !has_value {parse_error(p, "vel requires '=value'"); return false}
			v, ok := parse_number(p)
			if !ok {parse_error(p, "expected velocity"); return false}
			vel = i32(v)
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
		case "chan":
			if !has_value {parse_error(p, "chan requires '=value'"); return false}
			v, ok := parse_number(p)
			if !ok {parse_error(p, "expected channel"); return false}
			ch := i32(v)
			if ch < 1 || ch > 16 {
				parse_error(p, "channel must be 1..16, got %d", ch)
				return false
			}
			chan = u8(ch - 1)
		case:
			parse_error(p, "unknown reference argument: %s", arg_name)
			return false
		}
	}

	// Stash the target's index in `first`. It gets rewritten to the
	// target's actual children chain head by resolve_references after
	// every top-level body has been parsed.
	ref_idx := parser_add_event(
		p,
		parent,
		Source_Event {
			beat = quantize(beat),
			chance = chance,
			kind = Source_Timeline {
				first = target,
				channel = chan,
				transposition = trans,
				rate = rate,
				velocity = vel,
				free = free,
				scale = scale,
			},
		},
	)
	if ref_idx != NIL_SOURCE {
		// Refs don't have a name of their own; record the target's
		// name so the debug view can label it.
		p.names.lookup[ref_idx], _ = strings.clone(
			display_name,
			mem.arena_allocator(&p.names.arena),
		)
	}
	return true
}


// Parse the contents of a macro parameter list, with `(` already
// consumed. Stops after consuming `)`. Param names are bare
// identifiers separated by commas (or whitespace, since `,` is
// already treated as whitespace by the lexer).
@(private)
parse_macro_param_list :: proc(p: ^Parser) -> (params: []string, ok: bool) {
	buf: [MAX_MACRO_PARAMS]string
	count := 0
	for {
		skip_inline_ws(p)
		if p.pos >= len(p.src) {
			parse_error(p, "unterminated macro parameter list")
			return nil, false
		}
		if p.src[p.pos] == ')' {
			p.pos += 1
			p.col += 1
			break
		}
		name, n_ok := parse_ident(p)
		if !n_ok {
			parse_error(p, "expected macro parameter name")
			return nil, false
		}
		if count >= MAX_MACRO_PARAMS {
			parse_error(p, "too many macro parameters (max %d)", MAX_MACRO_PARAMS)
			return nil, false
		}
		buf[count] = name
		count += 1
	}
	out := make([]string, count)
	copy(out, buf[:count])
	return out, true
}


// Walk forward from current position to the end of the macro body
// (the next blank line or EOF or root-scope header). Returns a slice
// of `p.src` and leaves p.pos at the start of whatever comes after.
@(private)
capture_macro_body :: proc(p: ^Parser) -> string {
	body_start := p.pos
	body_end := body_start
	for {
		line_start := p.pos
		// Detect blank line: only horizontal whitespace and/or a
		// comment, then newline (or EOF).
		j := p.pos
		for j < len(p.src) && (p.src[j] == ' ' || p.src[j] == '\t' || p.src[j] == '\r' || p.src[j] == ',') {
			j += 1
		}
		if j < len(p.src) && p.src[j] == '#' {
			for j < len(p.src) && p.src[j] != '\n' do j += 1
		}
		blank := j >= len(p.src) || p.src[j] == '\n'
		if blank {
			p.pos = line_start
			break
		}
		// Otherwise this line is part of the body. Body extends through
		// the trailing newline so the recursive parser sees a clean line
		// boundary.
		skip_to_line_end(p)
		if p.pos < len(p.src) && p.src[p.pos] == '\n' {
			p.pos += 1
			p.line += 1
			p.col = 1
		}
		body_end = p.pos
	}
	return p.src[body_start:body_end]
}


// Parse the argument list for a macro invocation, with `(` already
// consumed. Each arg is captured as a raw text slice (a number literal
// or an identifier) — substitution into the macro body is purely
// textual.
@(private)
parse_macro_arg_list :: proc(p: ^Parser) -> (args: []string, ok: bool) {
	buf: [MAX_MACRO_ARGS]string
	count := 0
	for {
		skip_inline_ws(p)
		if p.pos >= len(p.src) {
			parse_error(p, "unterminated macro argument list")
			return nil, false
		}
		if p.src[p.pos] == ')' {
			p.pos += 1
			p.col += 1
			break
		}
		if count >= MAX_MACRO_ARGS {
			parse_error(p, "too many macro arguments (max %d)", MAX_MACRO_ARGS)
			return nil, false
		}
		// An argument is a contiguous run of non-whitespace, non-comma,
		// non-paren chars, so things like `3d` or `BASS` stay a single
		// token even though they'd lex as two pieces in normal grammar.
		// The text is substituted into the body verbatim.
		arg_start := p.pos
		for p.pos < len(p.src) {
			ac := p.src[p.pos]
			if is_macro_arg_terminator(ac) do break
			p.pos += 1
			p.col += 1
		}
		if p.pos == arg_start {
			parse_error(p, "empty macro argument")
			return nil, false
		}
		buf[count] = p.src[arg_start:p.pos]
		count += 1
	}
	out := make([]string, count)
	copy(out, buf[:count])
	return out, true
}


// Substitute `$name` tokens in `body` using the macro's params/args.
// Result is allocated in the parser scratch arena. Unknown `$name`
// is left intact (will produce a downstream parse error).
@(private)
substitute_macro_params :: proc(
	p: ^Parser,
	def: Macro_Def,
	args: []string,
) -> string {
	sb := strings.builder_make()
	body := def.body
	i := 0
	for i < len(body) {
		if body[i] == '$' && i + 1 < len(body) && is_ident_start(body[i + 1]) {
			j := i + 1
			for j < len(body) {
				ch := body[j]
				if !(is_alpha(ch) || is_digit(ch) || ch == '_') do break
				j += 1
			}
			pname := body[i + 1:j]
			arg_idx := -1
			for k in 0 ..< len(def.params) {
				if def.params[k] == pname {
					arg_idx = k
					break
				}
			}
			if arg_idx >= 0 {
				strings.write_string(&sb, args[arg_idx])
			} else {
				// Unknown placeholder — leave as-is so the recursive
				// parse surfaces a meaningful error at the right line.
				strings.write_byte(&sb, '$')
				strings.write_string(&sb, pname)
			}
			i = j
		} else {
			strings.write_byte(&sb, body[i])
			i += 1
		}
	}
	return strings.to_string(sb)
}


// Handle a macro invocation: NAME(...) on an event line. The name
// has already been consumed; we're sitting at `(`. Builds an
// anonymous `Source_Timeline` parented to `parent`, parses the
// substituted body into it, then reads any trailing beat / kwargs
// and treats the invocation like a ref to the anonymous timeline.
@(private)
parse_macro_invocation :: proc(p: ^Parser, name: string, parent: Source_Index) -> bool {
	def, found := p.macros[name]
	if !found {
		parse_error(p, "undefined macro: %s", name)
		return false
	}
	if p.macro_depth >= MAX_MACRO_DEPTH {
		parse_error(p, "macro expansion too deep (max %d) — recursive macro?", MAX_MACRO_DEPTH)
		return false
	}

	if !expect(p, '(') do return false
	args, a_ok := parse_macro_arg_list(p)
	if !a_ok do return false
	if len(args) != len(def.params) {
		parse_error(
			p,
			"macro %s expects %d argument(s), got %d",
			name,
			len(def.params),
			len(args),
		)
		return false
	}

	// Optional `!` after the invocation: `MACRO(...)!` is shorthand
	// for `MACRO(...) free=true`, same as on a regular ref.
	auto_free := false
	if p.pos < len(p.src) && p.src[p.pos] == '!' {
		p.pos += 1
		p.col += 1
		auto_free = true
	}

	// Memoize by (name, args). Each unique parameter combination is
	// equivalent to a distinct anonymous definition; further calls
	// with the same args (including a macro calling itself) emit a
	// ref to the already-built instance instead of recursing. The
	// instance is registered in the memo *before* its body is parsed
	// so a self-reference inside the body finds it.
	//
	// Refs to a macro instance use the full key as their display
	// name; that's what `adapt_to_source` keys off of to remap a
	// running macro-instance runtime across a reparse.
	key := build_macro_key(name, args)
	if existing, found := p.macro_instances_by_key[key]; found {
		return parse_ref_event_with_target(p, existing, key, parent, auto_free)
	}

	inst_idx := source_alloc(&p.source)
	if inst_idx == NIL_SOURCE {
		parse_error(p, "source storage full")
		return false
	}
	inst := source_get(&p.source, inst_idx)
	inst.chance = 100
	inst.kind = Source_Timeline{rate = 1}
	append(&p.macro_instances, inst_idx)
	p.macro_instances_by_key[key] = inst_idx

	body := substitute_macro_params(p, def, args)

	// Parse the substituted body into the anonymous timeline. Sub-chain
	// pointers must reset for the body parse so the macro's events land
	// in `inst_idx` rather than leaking into an enclosing sub-chain
	// (e.g., the else branch we may currently be inside).
	saved_src := p.src
	saved_pos := p.pos
	saved_line := p.line
	saved_col := p.col
	saved_sub_head := p.sub_chain_head
	saved_sub_tail := p.sub_chain_tail
	p.src = body
	p.pos = 0
	p.line = 1
	p.col = 1
	p.sub_chain_head = nil
	p.sub_chain_tail = nil
	p.macro_depth += 1
	body_ok := pass_2_body(p, inst_idx)
	p.macro_depth -= 1
	p.src = saved_src
	p.pos = saved_pos
	p.line = saved_line
	p.col = saved_col
	p.sub_chain_head = saved_sub_head
	p.sub_chain_tail = saved_sub_tail
	if !body_ok do return false

	// Now treat the invocation as a ref to the anon timeline. Read the
	// trailing beat and any kwargs (rate=, trans=, ...).
	return parse_ref_event_with_target(p, inst_idx, key, parent, auto_free)
}


// `if FIELD OP CONST [beat]` opens a conditional block.
//
// Layout produced:
//   - The fork is added to the parent's chain at the if-line beat.
//   - Then-branch events are added directly to the parent's chain
//     (so the natural `.next` walk from the fork follows the
//     then-branch).
//   - Else-branch events are added into an anonymous timeline whose
//     `.first` chain becomes `fork.else_first` — that's the only
//     edge into the else-branch.
//   - Both branch tails get patched, when the next event is added to
//     the parent (the post-if event), so the chain rejoins on a
//     single shared event. If no post-if event is parsed, tails stay
//     at NIL and the branches end the parent's chain.
//
// At runtime `play_timeline` lands on the fork, evaluates the
// predicate against the live parent, and redirects the cursor to
// either `cursor_event.next` (then-branch) or `fork.else_first`
// (else-branch); no synthetic timeline is allocated.
@(private)
parse_if_block :: proc(p: ^Parser, parent: Source_Index) -> bool {
	skip_inline_ws(p)
	field_name, ok_f := parse_ident(p)
	if !ok_f {
		parse_error(p, "expected predicate field after 'if'")
		return false
	}
	getter := lookup_predicate_getter(field_name)
	if getter == nil {
		parse_error(
			p,
			"unknown predicate field: %s (expected 'trans' or 'rate')",
			field_name,
		)
		return false
	}

	op_proc, ok_op := parse_op_token(p)
	if !ok_op {
		parse_error(p, "expected comparison operator (>, <, ==, !=, >=, <=)")
		return false
	}

	constant, ok_c := parse_number(p)
	if !ok_c {
		parse_error(p, "expected constant in predicate")
		return false
	}

	// `12d` selects the scale-degrees variant of `trans`. Mirrors the
	// `trans=2d` syntax on refs.
	if p.pos < len(p.src) && p.src[p.pos] == 'd' {
		p.pos += 1
		p.col += 1
		if field_name == "trans" {
			getter = get_trans_degrees
		} else {
			parse_error(p, "'d' suffix not supported on '%s'", field_name)
			return false
		}
	}

	skip_inline_ws(p)
	beat: f32 = 0
	if !at_line_end(p) {
		v, ok_b := parse_number(p)
		if !ok_b {
			parse_error(p, "unexpected content after predicate")
			return false
		}
		if v < 1 {parse_error(p, "time is 1-indexed; %.3g is invalid", v); return false}
		beat = v - 1
	}
	if !expect_line_end(p) do return false
	if p.pos < len(p.src) && p.src[p.pos] == '\n' {
		p.pos += 1
		p.line += 1
		p.col = 1
	}

	// Add the fork to the parent's chain. Its `.next` will be set by
	// the chain insertion logic when then-branch events arrive (they
	// follow the fork in beat order).
	fork_idx := parser_add_event(
		p,
		parent,
		Source_Event {
			beat = quantize(beat),
			chance = 100,
			kind = Source_Fork {
				get        = getter,
				op         = op_proc,
				constant   = constant,
				else_first = NIL_SOURCE,
			},
		},
	)
	if fork_idx == NIL_SOURCE {
		parse_error(p, "source storage full")
		return false
	}

	// Then-branch events are added directly to the parent's chain via
	// `parser_add_event`; their `.next` is set automatically by
	// `add_source_event`'s beat-ordered insertion when the post-if
	// event arrives, so no explicit pending-tail registration is
	// needed for the then-branch.
	saw_else: bool
	if !parse_fork_branch(p, parent, &saw_else) do return false

	if saw_else {
		// Parse the else-branch into a free-standing sub-chain whose
		// head/tail live on this stack frame. Routing through
		// `sub_chain_head`/`sub_chain_tail` makes `parser_add_event`
		// append into the sub-chain instead of the parent's main
		// chain. We save+restore the parser's previous sub-chain
		// pointers so nested if-blocks inside an else compose.
		else_head: Source_Index = NIL_SOURCE
		else_tail: Source_Index = NIL_SOURCE
		prev_head := p.sub_chain_head
		prev_tail := p.sub_chain_tail
		p.sub_chain_head = &else_head
		p.sub_chain_tail = &else_tail

		saw_else_again: bool
		branch_ok := parse_fork_branch(p, parent, &saw_else_again)

		p.sub_chain_head = prev_head
		p.sub_chain_tail = prev_tail
		if !branch_ok do return false
		if saw_else_again {
			parse_error(p, "duplicate 'else' in 'if' block")
			return false
		}

		(&source_get(&p.source, fork_idx).kind.(Source_Fork)).else_first = else_head
		if else_tail != NIL_SOURCE {
			append(&p.pending_tails, Pending_Tail{parent = parent, tail = else_tail})
		}
	}
	return true
}


// Parse the body of one if-branch — events go into `parent`. Stops
// when it sees `else` or `end` (consuming the keyword and its line).
// `end` is also implicit at the end of the enclosing definition: a
// blank line or EOF closes the branch (and cascades through any
// open outer if-blocks). The parser position is restored before the
// implicit terminator so the outer scope sees the blank/EOF
// normally and resets parent to root accordingly.
@(private)
parse_fork_branch :: proc(p: ^Parser, parent: Source_Index, saw_else: ^bool) -> bool {
	saw_else^ = false
	for {
		saved_pos := p.pos
		saved_line := p.line
		saved_col := p.col
		crossed_blank := skip_ws_track_blank(p)
		if crossed_blank || p.pos >= len(p.src) {
			p.pos = saved_pos
			p.line = saved_line
			p.col = saved_col
			return true
		}

		c := p.src[p.pos]

		if peek_line_has_colon(p) {
			parse_error(p, "definition not allowed inside 'if' block")
			return false
		}

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
			if !load_midi_into(p, path, parent, time) do return false
			continue
		}

		if num, is_cc := try_parse_cc_number(p); is_cc {
			if !parse_cc_event(p, parent, num) do return false
			continue
		}
		if lo, hi, is_note := try_parse_note_range(p); is_note {
			if !parse_note_event(p, parent, lo, hi) do return false
			continue
		}
		if dlo, olo, dhi, ohi, is_deg := try_parse_degree_range(p); is_deg {
			if !parse_degree_note_event(p, parent, dlo, olo, dhi, ohi) do return false
			continue
		}

		if !is_ident_start(c) {
			parse_error(p, "unexpected character %c", rune(c))
			return false
		}

		name, ok := parse_ident(p)
		if !ok {parse_error(p, "expected identifier"); return false}

		if name == "else" {
			saw_else^ = true
			if !expect_line_end(p) do return false
			return true
		}
		if name == "end" {
			// Leave the trailing newline in place so the caller's
			// skip_ws_track_blank can still see a blank line after the
			// if-block and reset to root scope.
			if !expect_line_end(p) do return false
			return true
		}
		if name == "if" {
			if !parse_if_block(p, parent) do return false
			continue
		}

		if p.pos < len(p.src) && p.src[p.pos] == '(' {
			if !parse_macro_invocation(p, name, parent) do return false
			continue
		}

		auto_free := false
		if p.pos < len(p.src) && p.src[p.pos] == '!' {
			p.pos += 1
			p.col += 1
			auto_free = true
		}

		if !parse_ref_event(p, name, parent, auto_free) do return false
	}
}


// Match a 1- or 2-character comparison operator at the current
// position. Advances past it on success and returns the matching
// op proc. Recognises >, <, ==, !=, >=, <=.
@(private)
parse_op_token :: proc(p: ^Parser) -> (op: Predicate_Op, ok: bool) {
	skip_inline_ws(p)
	if p.pos >= len(p.src) do return nil, false
	c := p.src[p.pos]
	next_c: u8 = 0
	if p.pos + 1 < len(p.src) do next_c = p.src[p.pos + 1]

	switch c {
	case '>':
		if next_c == '=' {
			p.pos += 2
			p.col += 2
			return op_geq, true
		}
		p.pos += 1
		p.col += 1
		return op_gt, true
	case '<':
		if next_c == '=' {
			p.pos += 2
			p.col += 2
			return op_leq, true
		}
		p.pos += 1
		p.col += 1
		return op_lt, true
	case '=':
		if next_c == '=' {
			p.pos += 2
			p.col += 2
			return op_eq, true
		}
	case '!':
		if next_c == '=' {
			p.pos += 2
			p.col += 2
			return op_neq, true
		}
	}
	return nil, false
}


@(private)
lookup_predicate_getter :: proc(name: string) -> Predicate_Getter {
	switch name {
	case "trans":
		return get_trans_semitones
	case "rate":
		return get_rate
	}
	return nil
}


@(private = "file")
is_macro_arg_terminator :: proc(c: u8) -> bool {
	return c == ',' || c == ')' || c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '#'
}


@(private = "file")
build_macro_key :: proc(name: string, args: []string) -> string {
	sb := strings.builder_make()
	strings.write_string(&sb, name)
	strings.write_byte(&sb, '(')
	for arg, i in args {
		if i > 0 do strings.write_byte(&sb, ',')
		strings.write_string(&sb, arg)
	}
	strings.write_byte(&sb, ')')
	return strings.to_string(sb)
}


NOTE_DEFAULT_VELOCITY :: 100
NOTE_DEFAULT_DURATION :: 1.0
NOTE_DEFAULT_CHANCE :: 100

// NOTE [time] [vel=V] [dur=D] [chance=C]
// The note name has already been consumed by try_parse_note_name;
// `pitch` is the resolved MIDI number.
@(private)
parse_note_event :: proc(p: ^Parser, parent: Source_Index, lo, hi: i32) -> bool {
	skip_inline_ws(p)
	beat: f32 = 0
	if !at_line_end(p) && !is_kwarg_start(p) {
		v, ok := parse_number(p)
		if !ok {parse_error(p, "expected time or kwarg"); return false}
		if v < 1 {parse_error(p, "time is 1-indexed; %.3g is invalid", v); return false}
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

	parser_add_event(
		p,
		parent,
		Source_Event {
			beat = quantize(beat),
			chance = chance,
			kind = Source_Note {
				number = Note_Number{pitch1 = u8(lo), pitch2 = u8(hi), is_degree = false},
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
	dlo, olo, dhi, ohi: i32,
) -> bool {
	skip_inline_ws(p)
	beat: f32 = 0
	if !at_line_end(p) && !is_kwarg_start(p) {
		v, ok := parse_number(p)
		if !ok {parse_error(p, "expected time or kwarg"); return false}
		if v < 1 {parse_error(p, "time is 1-indexed; %.3g is invalid", v); return false}
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

	parser_add_event(
		p,
		parent,
		Source_Event {
			beat = quantize(beat),
			chance = chance,
			kind = Source_Note {
				number = Note_Number {
					pitch1 = u8(dlo),
					octave1 = u8(olo),
					pitch2 = u8(dhi),
					octave2 = u8(ohi),
					is_degree = true,
				},
				velocity = vel,
				duration = max(quantize(dur), BEAT_QUANTUM),
			},
		},
	)
	return true
}


@(private)
try_parse_cc_number :: proc(p: ^Parser) -> (number: i32, ok: bool) {
	if p.pos + 2 >= len(p.src) do return 0, false
	if p.src[p.pos] != 'C' || p.src[p.pos + 1] != 'C' do return 0, false
	if !is_digit(p.src[p.pos + 2]) do return 0, false

	save_pos := p.pos
	save_col := p.col
	p.pos += 2
	p.col += 2

	n: i32 = 0
	for p.pos < len(p.src) && is_digit(p.src[p.pos]) {
		n = n * 10 + i32(p.src[p.pos] - '0')
		p.pos += 1
		p.col += 1
	}

	if p.pos < len(p.src) {
		c := p.src[p.pos]
		if is_alpha(c) || c == '_' {
			p.pos = save_pos
			p.col = save_col
			return 0, false
		}
	}
	return n, true
}


// CC<n> [time] val=V [chan=C] [chance=C]
@(private)
parse_cc_event :: proc(p: ^Parser, parent: Source_Index, number: i32) -> bool {
	if number < 0 || number >= 128 {
		parse_error(p, "CC number must be 0..127, got %d", number)
		return false
	}

	skip_inline_ws(p)
	beat: f32 = 0
	if !at_line_end(p) && !is_kwarg_start(p) {
		v, ok := parse_number(p)
		if !ok {parse_error(p, "expected time or kwarg"); return false}
		if v < 1 {parse_error(p, "time is 1-indexed; %.3g is invalid", v); return false}
		beat = v - 1
	}

	val: i32 = 0
	have_val := false
	chance: i32 = 100
	chan: Maybe(u8)

	for {
		if at_line_end(p) do break

		arg_name, ok_a := parse_ident(p)
		if !ok_a {parse_error(p, "expected argument name"); return false}
		if !expect(p, '=') do return false

		switch arg_name {
		case "val":
			v, ok := parse_number(p)
			if !ok {parse_error(p, "expected value"); return false}
			val = i32(v)
			have_val = true
		case "chance":
			c, ok := parse_number(p)
			if !ok {parse_error(p, "expected chance"); return false}
			chance = i32(c)
		case "chan":
			v, ok := parse_number(p)
			if !ok {parse_error(p, "expected channel"); return false}
			ch := i32(v)
			if ch < 1 || ch > 16 {parse_error(p, "channel must be 1..16, got %d", ch); return false}
			chan = u8(ch - 1)
		case:
			parse_error(p, "unknown CC argument: %s", arg_name)
			return false
		}
	}

	if !have_val {parse_error(p, "CC requires val=V"); return false}

	parser_add_event(
		p,
		parent,
		Source_Event {
			beat = quantize(beat),
			chance = chance,
			kind = Source_CC{number = number, value = val, channel = chan},
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
	prev_was_newline := false
	line_empty := true
	for p.pos < len(p.src) {
		switch p.src[p.pos] {
		case ' ', '\t', '\r', ',':
			p.pos += 1
			p.col += 1
		case '\n':
			if line_empty && prev_was_newline do crossed_blank = true
			p.pos += 1
			p.line += 1
			p.col = 1
			prev_was_newline = true
			line_empty = true
		case '#':
			line_empty = false
			for p.pos < len(p.src) && p.src[p.pos] != '\n' {
				p.pos += 1
				p.col += 1
			}
		case:
			return
		}
	}
	return
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
@(private)
try_parse_degree_range :: proc(p: ^Parser) -> (dlo, olo, dhi, ohi: i32, ok: bool) {
	d, o, ok1 := try_parse_degree_note(p)
	if !ok1 do return 0, 0, 0, 0, false
	if p.pos + 1 < len(p.src) && p.src[p.pos] == '-' {
		nx := p.src[p.pos + 1]
		if nx == 'P' || nx == 'p' {
			p.pos += 1
			p.col += 1
			d2, o2, ok2 := try_parse_degree_note(p)
			if !ok2 {
				parse_error(p, "expected degree note after '-' in range")
				return 0, 0, 0, 0, false
			}
			return d, o, d2, o2, true
		}
	}
	return d, o, d, o, true
}


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
try_parse_note_range :: proc(p: ^Parser) -> (lo, hi: i32, ok: bool) {
	v, ok1 := try_parse_note_name(p)
	if !ok1 do return 0, 0, false
	if p.pos + 1 < len(p.src) && p.src[p.pos] == '-' {
		if _, is_letter := note_letter_base(p.src[p.pos + 1]); is_letter {
			p.pos += 1
			p.col += 1
			v2, ok2 := try_parse_note_name(p)
			if !ok2 {
				parse_error(p, "expected note after '-' in range")
				return 0, 0, false
			}
			return v, v2, true
		}
	}
	return v, v, true
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
