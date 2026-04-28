package main

import "core:fmt"
import "core:mem"
import "seq"
import rl "vendor:raylib"


SONG_PATH :: "song.midiseq"
TEMP_ARENA_BYTES :: 1 * 1024 * 1024


draw_beat_counter :: proc(beat: f32, area: rl.Rectangle) {
	rl.DrawRectangleRounded(area, 0.15, 8, rl.Color{30, 30, 42, 255})
	rl.DrawRectangleRoundedLinesEx(area, 0.15, 8, 1.5, rl.Color{70, 70, 90, 255})

	ui_draw_text(
		"BEAT",
		i32(area.x) + 14,
		i32(area.y) + 10,
		14,
		rl.Color{140, 140, 160, 255},
	)

	text := fmt.ctprintf("%.2f", beat)
	size: i32 = 44
	width := ui_measure_text(text, size)
	ui_draw_text(
		text,
		i32(area.x + area.width / 2) - width / 2,
		i32(area.y) + 38,
		size,
		rl.Color{220, 230, 255, 255},
	)
}


// Parse `path` into `parser`. On success, rewire the runtime active
// chain onto the new source via `reparse_fixup`, swap the parser's
// source/names buffers into the sequencer, and continue ticking with
// in-flight notes intact. If the active chain is empty (initial load
// or everything got retired), spawn a fresh root via `start_sequencer`.
// Sequencer is left untouched on parse or read failure.
reload_song :: proc(sequencer: ^seq.Sequencer, parser: ^seq.Parser, path: string) -> bool {
	new_root, ok := seq.parse_file(parser, path)
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


try_start_sequencer :: proc(s: ^seq.Sequencer) {
	if s.source_root != seq.NIL_SOURCE do seq.start_sequencer(s)
}


main :: proc() {
	temp_buf := make([]byte, TEMP_ARENA_BYTES)
	defer delete(temp_buf)
	temp_arena: mem.Arena
	mem.arena_init(&temp_arena, temp_buf)
	context.temp_allocator = mem.arena_allocator(&temp_arena)

	midi: Midi_Out
	if !midi_open(&midi) do return
	defer midi_close(&midi)

	sequencer := seq.make_sequencer()
	defer seq.destroy_sequencer(&sequencer)
	sequencer.sink = midi_sink(&midi)
	sequencer.tempo = 120

	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)

	reload_song(&sequencer, &parser, SONG_PATH)

	watcher := File_Watcher {
		path = SONG_PATH,
	}
	file_watcher_poll(&watcher) // prime: first poll always returns true

	rl.SetConfigFlags({.WINDOW_RESIZABLE})
	rl.InitWindow(1400, 1000, "midiseq")
	defer rl.CloseWindow()
	rl.SetTargetFPS(120)

	load_ui_font()
	defer unload_ui_font()

	vis := make_visualizer()
	defer destroy_visualizer(&vis)

	playing := true
	show_debug := false

	for !rl.WindowShouldClose() {
		dt := rl.GetFrameTime()
		if rl.IsKeyPressed(.TAB) do show_debug = !show_debug
		if rl.IsKeyPressed(.SPACE) {
			shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
			if shift {
				if seq.sequencer_finished(&sequencer) {
					try_start_sequencer(&sequencer)
				}
				playing = true
			} else if playing {
				seq.silence(&sequencer)
				playing = false
			} else {
				seq.silence(&sequencer)
				try_start_sequencer(&sequencer)
				playing = true
			}
		}

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
				try_start_sequencer(&sequencer)
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
			try_start_sequencer(&sequencer)
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

		// Dashboard occupies the top DASHBOARD_H px and stays fixed; the
		// viz area below stretches with the window.
		DASHBOARD_H :: f32(160)
		BEAT_W :: f32(180)
		screen_w := f32(rl.GetScreenWidth())
		screen_h := f32(rl.GetScreenHeight())

		draw_beat_counter(sequencer.beat, rl.Rectangle{screen_w - BEAT_W - 20, 20, BEAT_W, 100})

		viz_area := rl.Rectangle{20, DASHBOARD_H, screen_w - 40, screen_h - DASHBOARD_H - 20}
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
