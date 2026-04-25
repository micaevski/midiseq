package main

import "core:fmt"
import "core:math"
import "seq"
import rl "vendor:raylib"


// Animation state for a single sounding note inside a lane.
Vis_Note :: struct {
	number: i32,
	appear: f32, // seconds since first seen, capped at APPEAR_TIME
	fade:   f32, // seconds since last seen; 0 while still sounding
	seen:   bool,
}

// One lane per active source ref. With the flat runtime model, multiple
// runtime instances of the same source ref collapse into a single lane.
// `source_idx` is the lane's stable key.
Vis_Lane :: struct {
	source_idx: seq.Source_Index,
	notes:      [dynamic]Vis_Note,
	appear:     f32,
	fade:       f32,
	seen:       bool,
}

Visualizer :: struct {
	lanes: [dynamic]Vis_Lane,
}

destroy_visualizer :: proc(vis: ^Visualizer) {
	for i in 0 ..< len(vis.lanes) do delete(vis.lanes[i].notes)
	delete(vis.lanes)
}

@(private = "file")
APPEAR_TIME :: f32(0.45)
@(private = "file")
FADE_TIME :: f32(0.60)
@(private = "file")
LANE_HEIGHT :: f32(60)
@(private = "file")
LANE_GAP :: f32(12)
@(private = "file")
NOTE_LO :: f32(36) // C2
@(private = "file")
NOTE_HI :: f32(96) // C7

@(private = "file")
find_lane :: proc(vis: ^Visualizer, source_idx: seq.Source_Index) -> int {
	for i in 0 ..< len(vis.lanes) {
		if vis.lanes[i].source_idx == source_idx do return i
	}
	append(&vis.lanes, Vis_Lane{source_idx = source_idx})
	return len(vis.lanes) - 1
}

// Notes are tracked per-lane by note number. A second voice on the same
// pitch retriggers the existing entry, which is fine — the animation
// still reads as "held".
@(private = "file")
find_note :: proc(lane: ^Vis_Lane, number: i32) -> int {
	for i in 0 ..< len(lane.notes) {
		if lane.notes[i].number == number && lane.notes[i].fade == 0 do return i
	}
	append(&lane.notes, Vis_Note{number = number})
	return len(lane.notes) - 1
}

@(private = "file")
lane_color :: proc(i: int, alpha: u8) -> rl.Color {
	palette := [?]rl.Color {
		{255, 120, 180, 0},
		{130, 200, 255, 0},
		{255, 200, 110, 0},
		{180, 255, 140, 0},
		{200, 160, 255, 0},
		{255, 150, 130, 0},
	}
	c := palette[i % len(palette)]
	c.a = alpha
	return c
}

// Walk the sequencer's flat active chain. Each Runtime_Timeline pins
// its lane as still-seen this frame; each Runtime_Note finds the lane
// for its `parent_source_idx` and is registered there. The root
// timeline (and any notes parented by it) are skipped — their lane
// would be visually noisy and isn't useful.
draw_active :: proc(vis: ^Visualizer, sequencer: ^seq.Sequencer, area: rl.Rectangle, dt: f32) {
	rl.DrawRectangleRec(area, rl.Color{18, 18, 24, 255})

	for i in 0 ..< len(vis.lanes) {
		vis.lanes[i].seen = false
		for j in 0 ..< len(vis.lanes[i].notes) {
			vis.lanes[i].notes[j].seen = false
		}
	}

	current := sequencer.active_head
	for current != seq.NIL_RUNTIME {
		e := seq.runtime_get(sequencer, current)
		next := e.active_next
		switch k in e.kind {
		case seq.Runtime_Note:
			// find_lane may grow vis.lanes; resolve the index first so
			// the slice access uses the post-append backing buffer.
			li := find_lane(vis, k.parent_source_idx)
			lane := &vis.lanes[li]
			ni := find_note(lane, k.number)
			lane.notes[ni].seen = true
		case seq.Runtime_Timeline:
			li := find_lane(vis, k.source_idx)
			vis.lanes[li].seen = true
		}
		current = next
	}

	// Advance/cull animation state.
	for i := 0; i < len(vis.lanes); {
		lane := &vis.lanes[i]
		if lane.seen {
			lane.appear = min(lane.appear + dt, APPEAR_TIME)
			lane.fade = 0
		} else {
			lane.fade += dt
		}

		for j := 0; j < len(lane.notes); {
			n := &lane.notes[j]
			if n.seen {
				n.appear = min(n.appear + dt, APPEAR_TIME)
				n.fade = 0
			} else {
				n.fade += dt
			}
			if n.fade > FADE_TIME {
				ordered_remove(&lane.notes, j)
			} else {
				j += 1
			}
		}

		if lane.fade > FADE_TIME {
			delete(lane.notes)
			ordered_remove(&vis.lanes, i)
		} else {
			i += 1
		}
	}

	LABEL_ZONE_W :: f32(80)
	NOTES_LEFT_PAD :: f32(16)
	note_range := NOTE_HI - NOTE_LO

	for i in 0 ..< len(vis.lanes) {
		lane := vis.lanes[i]
		lane_y := area.y + LANE_GAP + f32(i) * (LANE_HEIGHT + LANE_GAP)
		if lane_y + LANE_HEIGHT > area.y + area.height do break

		appear_t := clamp(lane.appear / APPEAR_TIME, 0, 1)
		fade_t := clamp(lane.fade / FADE_TIME, 0, 1)
		ease := 1 - (1 - appear_t) * (1 - appear_t)
		scale := ease * (1 - fade_t)
		alpha := u8(255 * (1 - fade_t))

		bg_h := LANE_HEIGHT * scale
		bg_y := lane_y + (LANE_HEIGHT - bg_h) * 0.5
		bg := rl.Rectangle{area.x + 12, bg_y, area.width - 24, bg_h}
		rl.DrawRectangleRounded(bg, 0.4, 6, rl.Color{30, 30, 42, alpha})

		baseline := lane_y + LANE_HEIGHT * 0.5
		col := lane_color(i, alpha)

		// Lane label, lit by the lane color.
		if name, has_name := sequencer.names.lookup[lane.source_idx]; has_name {
			name_size: i32 = 16
			ui_draw_text(
				fmt.ctprintf("%s", name),
				i32(area.x) + 20,
				i32(baseline) - name_size / 2,
				name_size,
				col,
			)
		}

		// Note bubbles live to the right of the label zone.
		notes_left := area.x + 12 + LABEL_ZONE_W + NOTES_LEFT_PAD
		notes_right := area.x + area.width - 12 - 12
		notes_w := notes_right - notes_left

		for j in 0 ..< len(lane.notes) {
			n := lane.notes[j]
			n_appear := clamp(n.appear / APPEAR_TIME, 0, 1)
			n_fade := clamp(n.fade / FADE_TIME, 0, 1)
			n_ease := 1 - (1 - n_appear) * (1 - n_appear)
			// Half-sine bounce: gentle overshoot on appear, settle while held.
			bounce := 1 + math.sin(n_appear * f32(math.PI)) * 0.35 * (1 - n_fade)
			n_scale := n_ease * (1 - n_fade) * bounce

			t_pos := clamp((f32(n.number) - NOTE_LO) / note_range, 0, 1)
			x := notes_left + t_pos * notes_w
			radius := f32(18) * n_scale

			rl.DrawCircleV(rl.Vector2{x, baseline}, radius, col)

			// Tiny offset highlight makes the dots look like little orbs.
			hi := rl.Color{255, 255, 255, alpha / 3}
			rl.DrawCircleV(rl.Vector2{x - radius * 0.3, baseline - radius * 0.3}, radius * 0.4, hi)

			label := fmt.ctprintf("%d", n.number)
			label_size: i32 = 18
			label_w := ui_measure_text(label, label_size)
			ui_draw_text(
				label,
				i32(x) - label_w / 2,
				i32(baseline) - label_size / 2,
				label_size,
				rl.Color{20, 20, 28, alpha},
			)
		}
	}
}
