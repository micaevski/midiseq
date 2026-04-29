package main

import "core:fmt"
import "core:mem"
import "seq"
import rl "vendor:raylib"


SONG_PATH :: "song.midiseq"
TEMP_ARENA_BYTES :: 1 * 1024 * 1024


draw_perf_counter :: proc(frame_ms: f32, fps: i32, area: rl.Rectangle) {
	rl.DrawRectangleRounded(area, 0.15, 8, rl.Color{30, 30, 42, 255})
	rl.DrawRectangleRoundedLinesEx(area, 0.15, 8, 1.5, rl.Color{70, 70, 90, 255})

	ui_draw_text("FRAME", i32(area.x) + 14, i32(area.y) + 10, 14, rl.Color{140, 140, 160, 255})

	text := fmt.ctprintf("%.2f ms", frame_ms)
	size: i32 = 32
	width := ui_measure_text(text, size)
	ui_draw_text(
		text,
		i32(area.x + area.width / 2) - width / 2,
		i32(area.y) + 30,
		size,
		rl.Color{180, 230, 180, 255},
	)

	fps_text := fmt.ctprintf("%d fps", fps)
	fps_size: i32 = 16
	fps_w := ui_measure_text(fps_text, fps_size)
	ui_draw_text(
		fps_text,
		i32(area.x + area.width / 2) - fps_w / 2,
		i32(area.y) + 70,
		fps_size,
		rl.Color{140, 180, 140, 255},
	)
}


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
	seq.adapt_to_source(sequencer, parser, new_root)

	if sequencer.active_head == seq.NIL_RUNTIME {
		seq.start(sequencer)
	}
	return true
}


try_start :: proc(s: ^seq.Sequencer, midi: ^Midi_Out) {
	if s.source_root != seq.NIL_SOURCE {
		seq.start(s)
		midi_reset(midi)
	}
}


ensure_no_more_allocations :: proc() -> mem.Allocator {
	when ODIN_DEBUG {
		return mem.panic_allocator()
	}
	return context.allocator
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
	frame_ms_ema: f32 = 0

	context.allocator = ensure_no_more_allocations()

	for !rl.WindowShouldClose() {
		dt := rl.GetFrameTime()
		frame_ms_ema = frame_ms_ema * 0.9 + dt * 1000 * 0.1
		if rl.IsKeyPressed(.TAB) do show_debug = !show_debug
		if rl.IsKeyPressed(.SPACE) {
			shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
			if shift {
				if seq.finished(&sequencer) {
					try_start(&sequencer, &midi)
				}
				playing = true
			} else if playing {
				seq.silence(&sequencer)
				playing = false
			} else {
				seq.silence(&sequencer)
				try_start(&sequencer, &midi)
				playing = true
			}
		}

		if file_watcher_poll(&watcher) {
			reload_song(&sequencer, &parser, SONG_PATH)
		}

		if playing && !seq.finished(&sequencer) {
			seq.tick(&sequencer, dt)
		}

		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)

		if rl.GuiButton(rl.Rectangle{20, 20, 100, 40}, "Start") {
			if seq.finished(&sequencer) {
				try_start(&sequencer, &midi)
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
			try_start(&sequencer, &midi)
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
		FOOTER_H :: f32(28)
		BEAT_W :: f32(180)
		screen_w := f32(rl.GetScreenWidth())
		screen_h := f32(rl.GetScreenHeight())

		draw_beat_counter(sequencer.beat, rl.Rectangle{screen_w - BEAT_W - 20, 20, BEAT_W, 100})
		if show_debug {
			PERF_W :: f32(200)
			draw_perf_counter(
				frame_ms_ema,
				rl.GetFPS(),
				rl.Rectangle{screen_w - BEAT_W - 20 - PERF_W - 12, 20, PERF_W, 100},
			)
		}

		viz_area := rl.Rectangle{20, DASHBOARD_H, screen_w - 40, screen_h - DASHBOARD_H - FOOTER_H}
		if show_debug {
			debug_draw_source(&sequencer, viz_area)
		} else {
			draw_active(&vis, &sequencer, viz_area, dt)
		}

		footer_area := rl.Rectangle{0, screen_h - FOOTER_H, screen_w, FOOTER_H}
		rl.DrawRectangleRec(footer_area, rl.Color{15, 15, 22, 255})
		err_msg: cstring
		if sequencer.tick_errors.pool_exhausted {
			err_msg = "sequencer: runtime pool exhausted; dropping events"
		} else if len(parser.last_error) > 0 {
			err_msg = fmt.ctprintf("%s", parser.last_error)
		}
		if err_msg != nil {
			ui_draw_text(err_msg, 12, i32(footer_area.y) + 7, 14, rl.Color{255, 110, 110, 255})
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
