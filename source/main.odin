package main

import "core:fmt"
import "core:mem"
import "seq"
import rl "vendor:raylib"


SONG_PATH :: "resources/song.midiseq"
TEMP_ARENA_BYTES :: 1 * 1024 * 1024


draw_pool_counter :: proc(label: cstring, used, total: i64, color: rl.Color, area: rl.Rectangle) {
	rl.DrawRectangleRounded(area, 0.15, 8, rl.Color{30, 30, 42, 255})
	rl.DrawRectangleRoundedLinesEx(area, 0.15, 8, 1.5, rl.Color{70, 70, 90, 255})

	ui_draw_text(label, i32(area.x) + 14, i32(area.y) + 10, 14, rl.Color{140, 140, 160, 255})

	text := fmt.ctprintf("%d", used)
	size: i32 = 32
	width := ui_measure_text(text, size)
	ui_draw_text(text, i32(area.x + area.width / 2) - width / 2, i32(area.y) + 30, size, color)

	sub := fmt.ctprintf("of %d", total)
	sub_size: i32 = 14
	sub_w := ui_measure_text(sub, sub_size)
	ui_draw_text(
		sub,
		i32(area.x + area.width / 2) - sub_w / 2,
		i32(area.y) + 72,
		sub_size,
		rl.Color{160, 160, 180, 255},
	)
}


draw_midi_counter :: proc(events_per_sec: f32, area: rl.Rectangle) {
	rl.DrawRectangleRounded(area, 0.15, 8, rl.Color{30, 30, 42, 255})
	rl.DrawRectangleRoundedLinesEx(area, 0.15, 8, 1.5, rl.Color{70, 70, 90, 255})

	ui_draw_text("MIDI", i32(area.x) + 14, i32(area.y) + 10, 14, rl.Color{140, 140, 160, 255})

	text := fmt.ctprintf("%.0f", events_per_sec)
	size: i32 = 32
	width := ui_measure_text(text, size)
	ui_draw_text(
		text,
		i32(area.x + area.width / 2) - width / 2,
		i32(area.y) + 30,
		size,
		rl.Color{220, 200, 130, 255},
	)

	sub: cstring = "events/sec"
	sub_size: i32 = 14
	sub_w := ui_measure_text(sub, sub_size)
	ui_draw_text(
		sub,
		i32(area.x + area.width / 2) - sub_w / 2,
		i32(area.y) + 72,
		sub_size,
		rl.Color{180, 160, 100, 255},
	)
}


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

	ui_draw_text("BEAT", i32(area.x) + 14, i32(area.y) + 10, 14, rl.Color{140, 140, 160, 255})

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
reload_song :: proc(sequencer: seq.Sequencer_Handle, parser: ^seq.Parser, path: string) -> bool {
	new_root, ok := seq.parse_file(parser, path)
	if !ok do return false

	// Rewire runtime cursors before the swap (uses old names + new
	// names.by_name, both alive at this point).
	seq.adapt_to_source(sequencer, parser, new_root)

	if seq.finished(sequencer) {
		seq.start(sequencer)
	}
	return true
}


Gui_State :: struct {
	show_debug:        bool,
	frame_ms_ema:      f32,
	in_dropdown_open:  bool,
	out_dropdown_open: bool,
	in_active:         i32,
	out_active:        i32,
}


// Render the dashboard, viz area, footer, and dropdowns. Caller is
// responsible for `rl.BeginDrawing()` / `rl.EndDrawing()` and
// `rl.ClearBackground` so it can sit in any larger frame structure.
draw_gui :: proc(
	ui: ^Gui_State,
	sequencer: seq.Sequencer_Handle,
	clock: seq.Clock_Handle,
	parser: ^seq.Parser,
	midi: ^Midi_IO,
	devices: ^Midi_Devices,
	config: ^Config,
) {
	// Labels for the MIDI dropdowns. The dropdown widgets themselves
	// are drawn at the END of the frame so their expanded option
	// lists overlay every other widget instead of being painted
	// over.
	ui_draw_text("MIDI In", 20, 24, 14, rl.Color{180, 180, 200, 255})
	ui_draw_text("MIDI Out", 380, 24, 14, rl.Color{180, 180, 200, 255})

	// Lock all other gui controls while a dropdown is open so clicks
	// inside the expanded list don't fall through to underlying
	// buttons.
	any_dropdown_open := ui.in_dropdown_open || ui.out_dropdown_open
	if any_dropdown_open do rl.GuiLock()

	if rl.GuiButton(rl.Rectangle{20, 60, 100, 40}, "Start") {
		if seq.finished(sequencer) {
			seq.start(sequencer)
		}
		seq.clock_set_playing(clock, true)
	}
	if rl.GuiButton(rl.Rectangle{140, 60, 100, 40}, "Pause") {
		if seq.clock_status(clock).playing {
			seq.silence(sequencer)
		}
		seq.clock_set_playing(clock, false)
	}
	if rl.GuiButton(rl.Rectangle{260, 60, 100, 40}, "Stop") {
		seq.silence(sequencer)
		seq.start(sequencer)
		seq.clock_set_playing(clock, false)
	}

	clock_status := seq.clock_status(clock)
	external := clock_status.mode == .External
	rl.GuiCheckBox(rl.Rectangle{400, 70, 20, 20}, "External Clock", &external)
	new_mode: seq.Clock_Mode = .External if external else .Internal
	if new_mode != clock_status.mode {
		seq.clock_set_mode(clock, new_mode)
		config.external_clock = external
		config_save(config, CONFIG_PATH)
	}
	if external {
		status: cstring = clock_status.external_running ? "running" : "stopped"
		label := fmt.ctprintf("ext: %.1f BPM (%s)", clock_status.bpm_ema, status)
		ui_draw_text(label, 540, 74, 14, rl.Color{180, 180, 200, 255})
	}

	tempo := clock_status.tempo
	tempo_label := fmt.ctprintf("%.0f BPM", tempo)
	rl.GuiSlider(rl.Rectangle{120, 120, 280, 20}, "Tempo", tempo_label, &tempo, 40, 240)
	if tempo != clock_status.tempo do seq.clock_set_tempo(clock, tempo)
	if rl.IsMouseButtonReleased(.LEFT) && tempo != config.tempo {
		config.tempo = tempo
		config_save(config, CONFIG_PATH)
	}

	// Dashboard occupies the top DASHBOARD_H px and stays fixed; the
	// viz area below stretches with the window.
	DASHBOARD_H :: f32(180)
	FOOTER_H :: f32(28)
	BEAT_W :: f32(180)
	screen_w := f32(rl.GetScreenWidth())
	screen_h := f32(rl.GetScreenHeight())

	draw_beat_counter(
		seq.sequencer_beat(sequencer),
		rl.Rectangle{screen_w - BEAT_W - 20, 60, BEAT_W, 100},
	)

	viz_area := rl.Rectangle{20, DASHBOARD_H, screen_w - 40, screen_h - DASHBOARD_H - FOOTER_H}
	if ui.show_debug {
		CARD_W :: f32(200)
		CARD_H :: f32(100)
		GAP :: f32(12)
		N :: 4
		row_w := f32(N) * CARD_W + f32(N - 1) * GAP
		row_x := viz_area.x + (viz_area.width - row_w) * 0.5
		row_y := viz_area.y + (viz_area.height - CARD_H) * 0.5
		card :: proc(x_base, y, w, h, gap: f32, i: int) -> rl.Rectangle {
			return rl.Rectangle{x_base + f32(i) * (w + gap), y, w, h}
		}
		draw_perf_counter(ui.frame_ms_ema, rl.GetFPS(), card(row_x, row_y, CARD_W, CARD_H, GAP, 0))
		when ODIN_DEBUG {
			draw_midi_counter(midi.events_per_sec, card(row_x, row_y, CARD_W, CARD_H, GAP, 1))
		}
		mem := seq.sequencer_memory(sequencer)
		draw_pool_counter(
			"RUNTIME",
			i64(mem.runtime_in_use),
			i64(mem.runtime_capacity),
			rl.Color{180, 220, 255, 255},
			card(row_x, row_y, CARD_W, CARD_H, GAP, 2),
		)
		draw_pool_counter(
			"SOURCE",
			i64(mem.source_in_use),
			i64(mem.source_capacity),
			rl.Color{200, 180, 255, 255},
			card(row_x, row_y, CARD_W, CARD_H, GAP, 3),
		)
	}

	footer_area := rl.Rectangle{0, screen_h - FOOTER_H, screen_w, FOOTER_H}
	rl.DrawRectangleRec(footer_area, rl.Color{15, 15, 22, 255})
	err_msg: cstring
	runtime_err := seq.sequencer_runtime_error(sequencer)
	if runtime_err.pool_exhausted {
		err_msg = "sequencer: runtime pool exhausted; dropping events"
	} else if runtime_err.empty {
		err_msg = "sequencer: nothing loaded"
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

	// MIDI device dropdowns drawn last so the expanded option list
	// floats over the rest of the dashboard. Unlock first because
	// the lock is meant for the rest of the controls only.
	if any_dropdown_open do rl.GuiUnlock()

	in_text := cstring(&devices.in_dropdown[0])
	out_text := cstring(&devices.out_dropdown[0])

	in_prev := ui.in_active
	if rl.GuiDropdownBox(
		rl.Rectangle{80, 18, 280, 28},
		in_text,
		&ui.in_active,
		ui.in_dropdown_open,
	) {
		ui.in_dropdown_open = !ui.in_dropdown_open
	}
	if ui.in_active != in_prev {
		midi_open_input_by_index(midi, devices, int(ui.in_active))
		config_set_in(config, midi_in_name(midi))
		config_save(config, CONFIG_PATH)
	}

	out_prev := ui.out_active
	if rl.GuiDropdownBox(
		rl.Rectangle{450, 18, 280, 28},
		out_text,
		&ui.out_active,
		ui.out_dropdown_open,
	) {
		ui.out_dropdown_open = !ui.out_dropdown_open
	}
	if ui.out_active != out_prev {
		midi_open_output_by_index(midi, devices, int(ui.out_active))
		config_set_out(config, midi_out_name(midi))
		config_save(config, CONFIG_PATH)
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

	devices: Midi_Devices
	midi: Midi_IO
	if !midi_init(&devices) do return
	defer midi_terminate(&midi)

	config: Config
	config_load(&config, CONFIG_PATH)
	ui: Gui_State
	ui.in_active = i32(midi_devices_find_in_index(&devices, config_in(&config)))
	ui.out_active = i32(midi_devices_find_out_index(&devices, config_out(&config)))
	midi_open_input_by_index(&midi, &devices, int(ui.in_active))
	midi_open_output_by_index(&midi, &devices, int(ui.out_active))

	// External clock requires a working input. If the saved input
	// device wasn't found, drop external mode and persist so a stale
	// `external_clock = true` doesn't get carried forward.
	if ui.in_active == 0 && config.external_clock {
		config.external_clock = false
		config_save(&config, CONFIG_PATH)
	}

	sequencer := seq.make_sequencer(midi_sink(&midi))
	defer seq.destroy_sequencer(sequencer)

	clock := seq.make_clock(config.tempo, .External if config.external_clock else .Internal)
	defer seq.destroy_clock(clock)

	parser := seq.make_parser()
	defer seq.destroy_parser(&parser)

	reload_song(sequencer, &parser, SONG_PATH)

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

	// Save the heap allocator so we can restore it after the main loop;
	// otherwise the defers above run with panic_allocator and trip on
	// their `delete` calls.
	heap_allocator := context.allocator
	context.allocator = ensure_no_more_allocations()

	for !rl.WindowShouldClose() {
		dt := rl.GetFrameTime()
		ui.frame_ms_ema = ui.frame_ms_ema * 0.9 + dt * 1000 * 0.1
		if rl.IsKeyPressed(.TAB) do ui.show_debug = !ui.show_debug
		if rl.IsKeyPressed(.SPACE) {
			shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
			playing := seq.clock_status(clock).playing
			if shift {
				if seq.finished(sequencer) {
					seq.start(sequencer)
				}
				seq.clock_set_playing(clock, true)
			} else if playing {
				seq.silence(sequencer)
				seq.clock_set_playing(clock, false)
			} else {
				seq.silence(sequencer)
				seq.start(sequencer)
				seq.clock_set_playing(clock, true)
			}
		}

		if file_watcher_poll(&watcher) {
			reload_song(sequencer, &parser, SONG_PATH)
		}

		// Drain any incoming MIDI messages. The clock owns all timing
		// state and updates itself; we handle the side-effects on the
		// sequencer (start/silence) here, since those would create a
		// package cycle if pushed into seq/clock.odin.
		now := rl.GetTime()
		mode := seq.clock_status(clock).mode
		for {
			event, data, ok := midi_read(&midi)
			if !ok do break
			if mode == .External {
				switch event {
				case .Start:
					seq.start(sequencer)
				case .Stop:
					seq.silence(sequencer)
				case .None, .Tick, .Continue, .Song_Position:
				}
			}
			seq.clock_process_event(clock, event, data, now)
		}
		seq.clock_tick(clock, dt)

		if seq.clock_is_running(clock) && !seq.finished(sequencer) {
			seq.tick(sequencer, seq.clock_status(clock).beat)
		}
		midi_end_frame(&midi, dt)

		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		draw_gui(&ui, sequencer, clock, &parser, &midi, &devices, &config)
		rl.EndDrawing()
		free_all(context.temp_allocator)
	}

	seq.silence(sequencer)
	rl.WaitTime(0.05)

	context.allocator = heap_allocator
}
