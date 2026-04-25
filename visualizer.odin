package main

import "core:fmt"
import "core:math"
import "seq"
import rl "vendor:raylib"


// Animation state for a single sounding note inside a lane.
Vis_Note :: struct {
	number:   i32,
	velocity: i32,
	appear:   f32, // seconds since first seen, capped at APPEAR_TIME
	fade:     f32, // seconds since last seen; 0 while still sounding
	seen:     bool,
}

// Animation state for one active timeline. Each active timeline (root or
// spawned) gets its own lane; lanes pop in on appear and fade out when
// the timeline retires.
Vis_Lane :: struct {
	timeline_idx: seq.Runtime_Index,
	notes:        [dynamic]Vis_Note,
	appear:       f32,
	fade:         f32,
	seen:         bool,
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
find_lane :: proc(vis: ^Visualizer, idx: seq.Runtime_Index) -> int {
	for i in 0 ..< len(vis.lanes) {
		if vis.lanes[i].timeline_idx == idx do return i
	}
	append(&vis.lanes, Vis_Lane{timeline_idx = idx})
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

// Walk the active chain of the given timeline and mark each Note entry
// as seen on `lane`. The runtime model only ever puts Notes directly in
// a timeline's active_head — sub-timelines bubble up to the root — so
// this is a single non-recursive pass. The owning timeline's
// transposition is added to each note number so what we draw matches
// the pitch that was actually sent to MIDI.
@(private = "file")
collect_notes :: proc(
	sequencer: ^seq.Sequencer,
	lane: ^Vis_Lane,
	timeline_idx: seq.Runtime_Index,
) {
	event := seq.runtime_get(sequencer, timeline_idx)
	timeline := event.kind.(seq.Runtime_Timeline)

	current := timeline.active_head
	for current != seq.NIL_RUNTIME {
		e := seq.runtime_get(sequencer, current)
		if note, ok := e.kind.(seq.Note); ok {
			sounding := note.number + timeline.transposition
			ni := find_note(lane, sounding)
			lane.notes[ni].velocity = note.velocity
			lane.notes[ni].seen = true
		}
		current = e.active_next
	}
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

// Walk the runtime tree from runtime_root, refresh each lane and note's
// animation state, and render the result inside `area`. Lanes pop in
// when they appear and shrink/fade when their timeline retires; notes
// pop in with a small overshoot and shrink away on note-off.
draw_active :: proc(vis: ^Visualizer, sequencer: ^seq.Sequencer, area: rl.Rectangle, dt: f32) {
	rl.DrawRectangleRec(area, rl.Color{18, 18, 24, 255})
	if sequencer.runtime_root == seq.NIL_RUNTIME do return

	for i in 0 ..< len(vis.lanes) {
		vis.lanes[i].seen = false
		for j in 0 ..< len(vis.lanes[i].notes) {
			vis.lanes[i].notes[j].seen = false
		}
	}

	// The root's active chain is the only one that holds Timeline
	// entries — sub-timelines bubble up to it during play. Walk it once:
	// notes feed the root lane; each Timeline gets its own lane.
	root := seq.runtime_get(sequencer, sequencer.runtime_root)
	root_timeline := root.kind.(seq.Runtime_Timeline)

	root_lane_i := find_lane(vis, sequencer.runtime_root)
	vis.lanes[root_lane_i].seen = true

	current := root_timeline.active_head
	for current != seq.NIL_RUNTIME {
		e := seq.runtime_get(sequencer, current)
		next := e.active_next
		switch k in e.kind {
		case seq.Note:
			sounding := k.number + root_timeline.transposition
			lane := &vis.lanes[find_lane(vis, sequencer.runtime_root)]
			ni := find_note(lane, sounding)
			lane.notes[ni].velocity = k.velocity
			lane.notes[ni].seen = true
		case seq.Runtime_Timeline:
			li := find_lane(vis, current)
			vis.lanes[li].seen = true
			collect_notes(sequencer, &vis.lanes[li], current)
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

	usable_w := area.width - 24
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

		for j in 0 ..< len(lane.notes) {
			n := lane.notes[j]
			n_appear := clamp(n.appear / APPEAR_TIME, 0, 1)
			n_fade := clamp(n.fade / FADE_TIME, 0, 1)
			n_ease := 1 - (1 - n_appear) * (1 - n_appear)
			// Half-sine bounce: gentle overshoot on appear, settle while held.
			bounce := 1 + math.sin(n_appear * f32(math.PI)) * 0.35 * (1 - n_fade)
			n_scale := n_ease * (1 - n_fade) * bounce

			t_pos := clamp((f32(n.number) - NOTE_LO) / note_range, 0, 1)
			x := area.x + 28 + t_pos * (usable_w - 20)
			radius := (14 + f32(n.velocity) * 0.10) * n_scale

			col := lane_color(i, alpha)
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
