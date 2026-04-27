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
