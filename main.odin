package main

import "seq"
import rl "vendor:raylib"


SOURCE :: `
CHORD_A = [
    note( 0 C5 vel=85 dur=0.3 )
    note( 0 E5 vel=85 dur=0.3 )
    note( 0 G5 vel=85 dur=0.3 )
]

CHORD_B = [
    note( 0 F5 vel=85 dur=0.3 )
    note( 0 A5 vel=85 dur=0.3 )
    note( 0 C6 vel=85 dur=0.3 )
]

PART_A = [
    CHORD_A(0)
    CHORD_A(1)
    CHORD_A(2)
    CHORD_A(3)
    PART_B(2)
]

PART_B = [
    CHORD_B(0)
    CHORD_B(1)
    CHORD_B(2)
    CHORD_B(3)
    PART_A(4)
]

SONG = [
    PART_A(0)
]


`


// Parse the DSL source, install it as the sequencer's root, and ready it
// for playback.
load_song :: proc(sequencer: ^seq.Sequencer, source: string) -> bool {
	root, ok := seq.parse_source(sequencer, source)
	if !ok do return false
	sequencer.root = root
	seq.start_sequencer(sequencer)
	return true
}


main :: proc() {
	midi: Midi_Out
	if !midi_open(&midi) do return
	defer midi_close(&midi)

	sequencer := seq.make_sequencer()
	defer seq.destroy_sequencer(&sequencer)
	sequencer.sink = midi_sink(&midi)
	sequencer.tempo = 120

	if !load_song(&sequencer, SOURCE) do return

	rl.InitWindow(480, 120, "midiseq")
	defer rl.CloseWindow()
	rl.SetTargetFPS(120)

	for !rl.WindowShouldClose() && !seq.sequencer_finished(&sequencer) {
		seq.sequencer_tick(&sequencer, rl.GetFrameTime())

		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		rl.DrawText("Playing. Esc to stop.", 20, 40, 20, rl.RAYWHITE)
		rl.EndDrawing()
	}

	midi_all_notes_off(&midi)
	rl.WaitTime(0.05)
}
