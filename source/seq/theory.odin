package seq


NOTE_NAMES := [12]string{"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}


// MIDI note number → letter and octave (e.g. 60 → "C", 4). Octave
// convention matches the parser: C4 = MIDI 60. Handles negative numbers
// via floor semantics so C-1 = 0 round-trips.
note_number_split :: proc(num: i32) -> (letter: string, octave: i32) {
	sem := num % 12
	oct := num / 12
	if sem < 0 {
		sem += 12
		oct -= 1
	}
	return NOTE_NAMES[sem], oct - 1
}


// Letter (case-insensitive) → semitone offset within an octave.
// Returns (0, false) if `c` is not one of A-G. Looks up the natural-name
// rows of NOTE_NAMES so the table stays the single source of truth.
note_letter_base :: proc(c: u8) -> (base: i32, ok: bool) {
	upper := c
	if upper >= 'a' && upper <= 'z' do upper -= 'a' - 'A'
	for name, i in NOTE_NAMES {
		if len(name) == 1 && name[0] == upper {
			return i32(i), true
		}
	}
	return 0, false
}


// ===== Scales =====

Scale_Kind :: enum u8 {
	None,
	Major,
	Minor,
	Pent_Major,
	Pent_Minor,
}

// A scale instance: a kind plus a root semitone offset (0..11 from C).
// Zero-value (`{None, 0}`) means "no scale set".
Scale :: struct {
	kind: Scale_Kind,
	root: u8,
}


Transposition :: struct {
	semitones: i16,
	degrees:   i16,
}


SCALE_NAME_HELP :: "format <root><kind>, root A-G with optional # or b, kind one of M (major), m (minor), PM (pent major), Pm (pent minor); e.g. CM, F#m, BbPM, EbPm"


degree_to_midi :: proc(degree, octave: i32, scale: Scale) -> i32 {
	offsets := scale_offsets(scale.kind)
	size := i32(len(offsets))
	if size == 0 {
		return (octave + 1) * 12 + (degree - 1)
	}
	octave_offset := floor_div(degree - 1, size)
	degree_idx := mod_pos(degree - 1, size)
	final_octave := octave + octave_offset
	pitch_class := mod_pos(i32(scale.root) + offsets[degree_idx], 12)
	return (final_octave + 1) * 12 + pitch_class
}


scale_size :: proc(scale: Scale) -> i32 {
	s := i32(len(scale_offsets(scale.kind)))
	if s == 0 do return 12
	return s
}


degrees_to_semitones :: proc(degrees: i32, scale: Scale) -> i32 {
	offsets := scale_offsets(scale.kind)
	size := i32(len(offsets))
	if size == 0 do return degrees
	octave_delta := floor_div(degrees, size)
	degree_idx := mod_pos(degrees, size)
	return offsets[degree_idx] + octave_delta * 12
}


midi_from_pos :: proc(pos: i32, scale: Scale) -> i32 {
	offsets := scale_offsets(scale.kind)
	size := i32(len(offsets))
	if size == 0 {
		return pos + 12
	}
	octave := floor_div(pos, size)
	degree_idx := mod_pos(pos, size)
	return degree_to_midi(degree_idx + 1, octave, scale)
}

// Scale-degree offsets in semitones from the scale's root, in ascending
// order. The first offset is always 0; the last is < 12.
@(private)
SCALE_MAJOR := [?]i32{0, 2, 4, 5, 7, 9, 11}
@(private)
SCALE_MINOR := [?]i32{0, 2, 3, 5, 7, 8, 10}
@(private)
SCALE_PENT_MAJ := [?]i32{0, 2, 4, 7, 9}
@(private)
SCALE_PENT_MIN := [?]i32{0, 3, 5, 7, 10}


// Returns the offsets slice for `kind`, or nil for `None`.
scale_offsets :: proc(kind: Scale_Kind) -> []i32 {
	switch kind {
	case .None:
		return nil
	case .Major:
		return SCALE_MAJOR[:]
	case .Minor:
		return SCALE_MINOR[:]
	case .Pent_Major:
		return SCALE_PENT_MAJ[:]
	case .Pent_Minor:
		return SCALE_PENT_MIN[:]
	}
	return nil
}


// Shift `pitch` (a MIDI note number) by `degrees` scale degrees within
// the scale defined by `root` (pitch class 0..11) and `offsets`
// (ascending semitone offsets from root within one octave; offsets[0]==0,
// last < 12). Pitches outside the scale round *down* to the nearest
// scale degree first, then step. So in CM:
//   C4  +2 → E4   (already in scale)
//   C#4 +2 → E4   (round down to C, then +2)
//   C#4 −2 → A3   (round down to C, then −2 wraps into prev octave)
// `degrees == 0` is identity. `len(offsets) == 0` falls back to a raw
// semitone shift.
shift_in_scale :: proc(pitch: i32, degrees: i32, root: i32, offsets: []i32) -> i32 {
	if degrees == 0 do return pitch
	size := i32(len(offsets))
	if size == 0 do return pitch + degrees

	// Position of `pitch` relative to the scale root.
	rel := pitch - root
	rel_offset := mod_pos(rel, 12)
	scale_octave := (rel - rel_offset) / 12

	// Largest degree whose offset is ≤ rel_offset (round down).
	degree_idx: i32 = 0
	for i in 1 ..< size {
		if offsets[i] > rel_offset do break
		degree_idx = i
	}

	// Apply the shift; quotient = octave delta, remainder = new degree.
	new_index := degree_idx + degrees
	octave_delta := floor_div(new_index, size)
	new_degree := mod_pos(new_index, size)

	return root + (scale_octave + octave_delta) * 12 + offsets[new_degree]
}


@(private)
mod_pos :: proc(a, m: i32) -> i32 {
	r := a % m
	if r < 0 do r += m
	return r
}


@(private)
floor_div :: proc(a, m: i32) -> i32 {
	return (a - mod_pos(a, m)) / m
}


// Parse a scale name like "CM", "Am", "F#PM", "BbPm". The root letter is
// case-insensitive and may be followed by a single accidental ('#' raises
// by a semitone, 'b' lowers). The suffix selects the scale type and is
// case-sensitive: M = major, m = minor, PM = pentatonic major, Pm =
// pentatonic minor.
parse_scale_name :: proc(s: string) -> (Scale, bool) {
	if len(s) < 2 do return {}, false
	base, ok := note_letter_base(s[0])
	if !ok do return {}, false

	pos := 1
	if pos < len(s) {
		switch s[pos] {
		case '#':
			base += 1
			pos += 1
		case 'b':
			base -= 1
			pos += 1
		}
	}
	// Wrap accidental result into 0..11.
	base = ((base % 12) + 12) % 12

	kind: Scale_Kind
	switch s[pos:] {
	case "M":
		kind = .Major
	case "m":
		kind = .Minor
	case "PM":
		kind = .Pent_Major
	case "Pm":
		kind = .Pent_Minor
	case:
		return {}, false
	}
	return Scale{kind = kind, root = u8(base)}, true
}
