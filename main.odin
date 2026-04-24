package main

import rl "vendor:raylib"
import "seq"


SOURCE :: `
A = [
    (0,   0.4, (60, 100)),
    (0.5, 0.4, (62, 100)),
    (1,   0.4, (64, 100)),
    (1.5, 0.4, (67, 100)),
    (2, A)
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
