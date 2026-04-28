package tests

import "../seq"
import "core:testing"


@(test)
test_note_number_split :: proc(t: ^testing.T) {
	letter, octave := seq.note_number_split(60)
	testing.expect_value(t, letter, "C")
	testing.expect_value(t, octave, i32(4))

	letter, octave = seq.note_number_split(69)
	testing.expect_value(t, letter, "A")
	testing.expect_value(t, octave, i32(4))

	letter, octave = seq.note_number_split(72)
	testing.expect_value(t, letter, "C")
	testing.expect_value(t, octave, i32(5))

	letter, octave = seq.note_number_split(0)
	testing.expect_value(t, letter, "C")
	testing.expect_value(t, octave, i32(-1))

	// Negative MIDI: floor semantics so C-2 = -12 round-trips.
	letter, octave = seq.note_number_split(-12)
	testing.expect_value(t, letter, "C")
	testing.expect_value(t, octave, i32(-2))

	letter, octave = seq.note_number_split(-1)
	testing.expect_value(t, letter, "B")
	testing.expect_value(t, octave, i32(-2))
}


@(test)
test_note_letter_base :: proc(t: ^testing.T) {
	base, ok := seq.note_letter_base('C')
	testing.expect(t, ok)
	testing.expect_value(t, base, i32(0))

	base, ok = seq.note_letter_base('A')
	testing.expect(t, ok)
	testing.expect_value(t, base, i32(9))

	// case-insensitive
	base, ok = seq.note_letter_base('a')
	testing.expect(t, ok)
	testing.expect_value(t, base, i32(9))

	base, ok = seq.note_letter_base('g')
	testing.expect(t, ok)
	testing.expect_value(t, base, i32(7))

	// rejects non-letters
	_, ok = seq.note_letter_base('X')
	testing.expect(t, !ok)

	_, ok = seq.note_letter_base('1')
	testing.expect(t, !ok)
}


@(test)
test_parse_scale_name :: proc(t: ^testing.T) {
	s, ok := seq.parse_scale_name("CM")
	testing.expect(t, ok)
	testing.expect_value(t, s.kind, seq.Scale_Kind.Major)
	testing.expect_value(t, s.root, i32(0))

	s, ok = seq.parse_scale_name("Am")
	testing.expect(t, ok)
	testing.expect_value(t, s.kind, seq.Scale_Kind.Minor)
	testing.expect_value(t, s.root, i32(9))

	s, ok = seq.parse_scale_name("F#PM")
	testing.expect(t, ok)
	testing.expect_value(t, s.kind, seq.Scale_Kind.Pent_Major)
	testing.expect_value(t, s.root, i32(6))

	s, ok = seq.parse_scale_name("BbPm")
	testing.expect(t, ok)
	testing.expect_value(t, s.kind, seq.Scale_Kind.Pent_Minor)
	testing.expect_value(t, s.root, i32(10))

	// Cb wraps to B (pitch class 11).
	s, ok = seq.parse_scale_name("Cbm")
	testing.expect(t, ok)
	testing.expect_value(t, s.root, i32(11))

	// case-insensitive root letter.
	s, ok = seq.parse_scale_name("cM")
	testing.expect(t, ok)
	testing.expect_value(t, s.root, i32(0))

	// Invalid: unknown suffix.
	_, ok = seq.parse_scale_name("CMx")
	testing.expect(t, !ok)

	// Invalid: non-letter root.
	_, ok = seq.parse_scale_name("XX")
	testing.expect(t, !ok)

	// Invalid: missing suffix.
	_, ok = seq.parse_scale_name("Cb")
	testing.expect(t, !ok)

	// Invalid: too short.
	_, ok = seq.parse_scale_name("C")
	testing.expect(t, !ok)

	_, ok = seq.parse_scale_name("")
	testing.expect(t, !ok)
}


@(test)
test_scale_offsets_none :: proc(t: ^testing.T) {
	testing.expect_value(t, len(seq.scale_offsets(.None)), 0)
}


@(test)
test_shift_in_scale_cm :: proc(t: ^testing.T) {
	cm := seq.scale_offsets(.Major)

	// degrees == 0 is identity even off-scale.
	testing.expect_value(t, seq.shift_in_scale(60, 0, 0, cm), i32(60))
	testing.expect_value(t, seq.shift_in_scale(61, 0, 0, cm), i32(61))

	// In-scale starting points.
	testing.expect_value(t, seq.shift_in_scale(60, 2, 0, cm), i32(64)) // C4 +2 = E4
	testing.expect_value(t, seq.shift_in_scale(60, -1, 0, cm), i32(59)) // C4 -1 = B3
	testing.expect_value(t, seq.shift_in_scale(64, 1, 0, cm), i32(65)) // E4 +1 = F4

	// Out-of-scale rounds *down* before stepping.
	testing.expect_value(t, seq.shift_in_scale(61, 2, 0, cm), i32(64)) // C#4 +2 → C +2 = E4
	testing.expect_value(t, seq.shift_in_scale(61, -2, 0, cm), i32(57)) // C#4 -2 → C -2 = A3
	testing.expect_value(t, seq.shift_in_scale(63, 1, 0, cm), i32(64)) // D#4 +1 → D +1 = E4

	// Octave wraps.
	testing.expect_value(t, seq.shift_in_scale(71, 1, 0, cm), i32(72)) // B4 +1 = C5
	testing.expect_value(t, seq.shift_in_scale(72, -1, 0, cm), i32(71)) // C5 -1 = B4
	testing.expect_value(t, seq.shift_in_scale(60, 7, 0, cm), i32(72)) // +full scale-octave
	testing.expect_value(t, seq.shift_in_scale(60, -7, 0, cm), i32(48))
	testing.expect_value(t, seq.shift_in_scale(60, 14, 0, cm), i32(84)) // +two scale-octaves
}


@(test)
test_shift_in_scale_a_major :: proc(t: ^testing.T) {
	am := seq.scale_offsets(.Major)
	root := i32(9) // A

	// AM scale: A B C# D E F# G#.
	// C4 (60) is between B and C# in AM → rounds down to B (degree 1).
	testing.expect_value(t, seq.shift_in_scale(60, 1, root, am), i32(61)) // C4 +1 → B+1 = C#4
	testing.expect_value(t, seq.shift_in_scale(60, 0, root, am), i32(60)) // identity

	// G#4 +1 → A4 (top-of-octave wrap, degree 6 → 7 mod 7 = 0 next octave).
	testing.expect_value(t, seq.shift_in_scale(68, 1, root, am), i32(69))

	// A4 -1 → G#4.
	testing.expect_value(t, seq.shift_in_scale(69, -1, root, am), i32(68))
}


@(test)
test_shift_in_scale_e_minor :: proc(t: ^testing.T) {
	em := seq.scale_offsets(.Minor)
	root := i32(4) // E

	// E minor: E F# G A B C D.
	testing.expect_value(t, seq.shift_in_scale(64, 1, root, em), i32(66)) // E4 +1 = F#4
	testing.expect_value(t, seq.shift_in_scale(64, 2, root, em), i32(67)) // E4 +2 = G4
	testing.expect_value(t, seq.shift_in_scale(64, 7, root, em), i32(76)) // +full scale-octave
	testing.expect_value(t, seq.shift_in_scale(64, -1, root, em), i32(62)) // E4 -1 = D4

	// F4 (65) is between E and F# in Em → rounds down to E (degree 0).
	testing.expect_value(t, seq.shift_in_scale(65, 1, root, em), i32(66))

	// D5 (74) +1 → E5 (top wrap, degree 6 → 7 mod 7 = 0 next octave).
	testing.expect_value(t, seq.shift_in_scale(74, 1, root, em), i32(76))
}


@(test)
test_shift_in_scale_pentatonic_major :: proc(t: ^testing.T) {
	pm := seq.scale_offsets(.Pent_Major)

	// CPM: C D E G A (offsets 0, 2, 4, 7, 9). Five degrees per octave.
	testing.expect_value(t, seq.shift_in_scale(60, 1, 0, pm), i32(62)) // C4 +1 = D4
	testing.expect_value(t, seq.shift_in_scale(60, 3, 0, pm), i32(67)) // C4 +3 = G4
	testing.expect_value(t, seq.shift_in_scale(60, 5, 0, pm), i32(72)) // +full pent-octave
	testing.expect_value(t, seq.shift_in_scale(69, 1, 0, pm), i32(72)) // A4 +1 = C5

	// F4 (65) is not in CPM; rounds down to E (degree 2). +1 → G (degree 3).
	testing.expect_value(t, seq.shift_in_scale(65, 1, 0, pm), i32(67))
}


@(test)
test_shift_in_scale_pentatonic_minor :: proc(t: ^testing.T) {
	pm := seq.scale_offsets(.Pent_Minor)
	root := i32(9) // A

	// A pent minor: A C D E G (offsets 0, 3, 5, 7, 10 from root A).
	testing.expect_value(t, seq.shift_in_scale(69, 1, root, pm), i32(72)) // A4 +1 = C5
	testing.expect_value(t, seq.shift_in_scale(69, 4, root, pm), i32(79)) // A4 +4 = G5
	testing.expect_value(t, seq.shift_in_scale(69, 5, root, pm), i32(81)) // +full pent-octave
	testing.expect_value(t, seq.shift_in_scale(72, -1, root, pm), i32(69)) // C5 -1 = A4

	// B4 (71) is not in APm; rounds down to A (degree 0). +1 → C5.
	testing.expect_value(t, seq.shift_in_scale(71, 1, root, pm), i32(72))

	// G5 (79) +1 → A5 (top wrap, degree 4 → 5 mod 5 = 0 next octave).
	testing.expect_value(t, seq.shift_in_scale(79, 1, root, pm), i32(81))
}


@(test)
test_shift_in_scale_chromatic_fallback :: proc(t: ^testing.T) {
	// nil/empty offsets falls back to a raw semitone shift.
	testing.expect_value(t, seq.shift_in_scale(60, 5, 0, nil), i32(65))
	testing.expect_value(t, seq.shift_in_scale(60, -5, 0, nil), i32(55))
	testing.expect_value(t, seq.shift_in_scale(60, 0, 0, nil), i32(60))
}


@(test)
test_shift_in_scale_negative_pitch :: proc(t: ^testing.T) {
	cm := seq.scale_offsets(.Major)

	// MIDI 0 (C-1) -1 in CM → B-2 (MIDI -1). Math should still hold below 0.
	testing.expect_value(t, seq.shift_in_scale(0, -1, 0, cm), i32(-1))

	// MIDI -1 (B-2) +1 in CM → C-1 (MIDI 0).
	testing.expect_value(t, seq.shift_in_scale(-1, 1, 0, cm), i32(0))
}
