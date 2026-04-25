package main

import "core:fmt"
import "core:os"
import "seq"
import rl "vendor:raylib"


SONG_PATH :: "song.midiseq"


// Parse the DSL source, install it as the sequencer's root, and ready it
// for playback.
load_song :: proc(sequencer: ^seq.Sequencer, source: string) -> bool {
	root, ok := seq.parse_source(sequencer, source)
	if !ok do return false
	sequencer.source_root = root
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

	source_bytes, read_err := os.read_entire_file(SONG_PATH, context.allocator)
	if read_err != nil {
		fmt.eprintfln("could not read %s: %v", SONG_PATH, read_err)
		return
	}
	defer delete(source_bytes)
	if !load_song(&sequencer, string(source_bytes)) do return

	rl.InitWindow(900, 760, "midiseq")
	defer rl.CloseWindow()
	rl.SetTargetFPS(120)

	load_ui_font()
	defer unload_ui_font()

	vis: Visualizer
	defer destroy_visualizer(&vis)

	playing := true
	show_debug := false

	for !rl.WindowShouldClose() {
		dt := rl.GetFrameTime()
		if rl.IsKeyPressed(.TAB) do show_debug = !show_debug

		if playing && !seq.sequencer_finished(&sequencer) {
			seq.sequencer_tick(&sequencer, dt)
		}

		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)

		if rl.GuiButton(rl.Rectangle{20, 20, 100, 40}, "Start") {
			if seq.sequencer_finished(&sequencer) {
				seq.start_sequencer(&sequencer)
			}
			playing = true
		}
		if rl.GuiButton(rl.Rectangle{140, 20, 100, 40}, "Pause") {
			if playing {
				midi_all_notes_off(&midi)
			}
			playing = false
		}
		if rl.GuiButton(rl.Rectangle{260, 20, 100, 40}, "Stop") {
			midi_all_notes_off(&midi)
			seq.start_sequencer(&sequencer)
			playing = false
		}

		tempo_label := fmt.ctprintf("%.0f BPM", sequencer.tempo)
		rl.GuiSlider(
			rl.Rectangle{120, 100, 280, 20},
			"Tempo",
			tempo_label,
			&sequencer.tempo,
			40,
			240,
		)

		viz_area := rl.Rectangle{20, 160, 860, 580}
		if show_debug {
			debug_draw_source(&sequencer, viz_area)
		} else {
			draw_active(&vis, &sequencer, viz_area, dt)
		}
		ui_draw_text("[TAB] toggle debug", i32(viz_area.x) + 8, i32(viz_area.y + viz_area.height) - 20, 14, rl.GRAY)

		rl.EndDrawing()
		free_all(context.temp_allocator)
	}

	midi_all_notes_off(&midi)
	rl.WaitTime(0.05)
}
