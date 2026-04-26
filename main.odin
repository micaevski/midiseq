package main

import "core:fmt"
import "core:os"
import "seq"
import rl "vendor:raylib"


SONG_PATH :: "song.midiseq"


// Parse `path` into `parser`. On success, rewire the runtime active
// chain onto the new source via `reparse_fixup`, swap the parser's
// source/names buffers into the sequencer, and continue ticking with
// in-flight notes intact. If the active chain is empty (initial load
// or everything got retired), spawn a fresh root via `start_sequencer`.
// Sequencer is left untouched on parse or read failure.
reload_song :: proc(sequencer: ^seq.Sequencer, parser: ^seq.Parser, path: string) -> bool {
	bytes, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("could not read %s: %v", path, err)
		return false
	}
	defer delete(bytes)

	new_root, ok := seq.parse_source(parser, string(bytes))
	if !ok do return false

	// Rewire runtime cursors before the swap (uses old names + new
	// names.by_name, both alive at this point).
	seq.adapt_to_source(sequencer, &parser.source, &parser.names, new_root)

	// Ping-pong: parser ↔ sequencer.
	parser.source, sequencer.source = sequencer.source, parser.source
	parser.names, sequencer.names = sequencer.names, parser.names

	sequencer.source_root = new_root
	sequencer.rng_state = parser.rng_state

	if sequencer.active_head == seq.NIL_RUNTIME {
		seq.start_sequencer(sequencer)
	}
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

	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)

	if !reload_song(&sequencer, &parser, SONG_PATH) do return

	watcher := File_Watcher {
		path = SONG_PATH,
	}
	file_watcher_poll(&watcher) // prime: first poll always returns true

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

		if file_watcher_poll(&watcher) {
			reload_song(&sequencer, &parser, SONG_PATH)
		}

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
				seq.silence(&sequencer)
			}
			playing = false
		}
		if rl.GuiButton(rl.Rectangle{260, 20, 100, 40}, "Stop") {
			seq.silence(&sequencer)
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
		ui_draw_text(
			"[TAB] toggle debug",
			i32(viz_area.x) + 8,
			i32(viz_area.y + viz_area.height) - 20,
			14,
			rl.GRAY,
		)

		rl.EndDrawing()
		free_all(context.temp_allocator)
	}

	seq.silence(&sequencer)
	rl.WaitTime(0.05)
}
