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
	root: i32,
}

// Per-degree intervals in semitones. Each slice sums to 12 (one octave).
@(private)
SCALE_MAJOR := [?]i32{2, 2, 1, 2, 2, 2, 1}
@(private)
SCALE_MINOR := [?]i32{2, 1, 2, 2, 1, 2, 2}
@(private)
SCALE_PENT_MAJ := [?]i32{2, 2, 3, 2, 3}
@(private)
SCALE_PENT_MIN := [?]i32{3, 2, 2, 3, 2}


// Returns the interval slice for `kind`, or nil for `None`.
scale_intervals :: proc(kind: Scale_Kind) -> []i32 {
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
	return Scale{kind = kind, root = base}, true
}
