package main

import "core:fmt"
import "core:math"
import "seq"
import rl "vendor:raylib"


@(private = "file")
DBG_CELL_W :: f32(320)
@(private = "file")
DBG_CELL_H :: f32(60)
@(private = "file")
DBG_TOP_PAD :: f32(20)
@(private = "file")
DBG_SCROLL_SPEED :: f32(40)


// Persistent vertical scroll offset, in pixels. Mouse wheel updates it
// while the cursor is over the area.
@(private = "file")
debug_scroll: f32


// Render the source pool as a single vertical column of stacked cells
// (one per occupied slot from index 1 up to source_pool.count). The
// bidirectional prev/next sibling arrow runs down the left side; the
// timeline-only `first` arrow runs down the right side. Mouse wheel
// scrolls the column when the cursor is over the area.
debug_draw_source :: proc(sequencer: ^seq.Sequencer, area: rl.Rectangle) {
	rl.DrawRectangleRec(area, rl.Color{14, 14, 20, 255})

	count := i32(len(sequencer.source))
	if count <= 1 do return

	total_h := DBG_TOP_PAD * 2 + f32(count - 1) * DBG_CELL_H
	max_scroll := max(0, total_h - area.height)

	if rl.CheckCollisionPointRec(rl.GetMousePosition(), area) {
		debug_scroll -= rl.GetMouseWheelMove() * DBG_SCROLL_SPEED
	}
	debug_scroll = clamp(debug_scroll, 0, max_scroll)

	rl.BeginScissorMode(i32(area.x), i32(area.y), i32(area.width), i32(area.height))

	SIBLING_COLOR :: rl.Color{120, 220, 140, 230}
	FIRST_COLOR :: rl.Color{120, 200, 255, 230}

	// Arrows under cells so line bodies don't clip the cell text.
	for idx: i32 = 1; idx < count; idx += 1 {
		e := seq.source_get(&sequencer.source, seq.Source_Index(idx))
		from := debug_cell_rect(idx, area)
		if e.next != seq.NIL_SOURCE {
			to := debug_cell_rect(i32(e.next), area)
			debug_draw_side_arrow(from, to, SIBLING_COLOR, false, true)
		}
		if t, ok := e.kind.(seq.Source_Timeline); ok && t.first != seq.NIL_SOURCE {
			to := debug_cell_rect(i32(t.first), area)
			debug_draw_side_arrow(from, to, FIRST_COLOR, true, false)
		}
	}

	for idx: i32 = 1; idx < count; idx += 1 {
		debug_draw_cell(sequencer, idx, area)
	}

	rl.EndScissorMode()

	debug_draw_scrollbar(area, total_h, max_scroll)
	debug_draw_legend(area, SIBLING_COLOR, FIRST_COLOR)
}


@(private = "file")
debug_cell_rect :: proc(idx: i32, area: rl.Rectangle) -> rl.Rectangle {
	x := area.x + (area.width - DBG_CELL_W) * 0.5
	y := area.y + DBG_TOP_PAD + f32(idx - 1) * DBG_CELL_H - debug_scroll
	return rl.Rectangle{x, y, DBG_CELL_W, DBG_CELL_H}
}


@(private = "file")
debug_draw_cell :: proc(sequencer: ^seq.Sequencer, idx: i32, area: rl.Rectangle) {
	e := seq.source_get(&sequencer.source, seq.Source_Index(idx))
	r := debug_cell_rect(idx, area)

	// Skip work for cells fully scrolled off either edge.
	if r.y + r.height < area.y || r.y > area.y + area.height do return

	rl.DrawRectangleRec(r, rl.Color{32, 32, 44, 255})
	rl.DrawRectangleLinesEx(r, 1, rl.Color{90, 90, 110, 255})

	title: cstring = "Note"
	if _, is_timeline := e.kind.(seq.Source_Timeline); is_timeline {
		if name, has_name := sequencer.names.lookup[seq.Source_Index(idx)]; has_name {
			title = fmt.ctprintf("%s", name)
		} else {
			title = "Timeline"
		}
	}
	ui_draw_text(
		fmt.ctprintf("[%d] %s", idx, title),
		i32(r.x) + 12,
		i32(r.y) + 8,
		16,
		rl.WHITE,
	)

	switch k in e.kind {
	case seq.Note:
		ui_draw_text(
			fmt.ctprintf("n=%d  v=%d  beat=%.2f", k.number, k.velocity, e.beat),
			i32(r.x) + 12,
			i32(r.y) + 32,
			14,
			rl.LIGHTGRAY,
		)
	case seq.Source_Timeline:
		ui_draw_text(
			fmt.ctprintf(
				"trans=%d/%dd  rate=%.1f  beat=%.2f",
				k.transposition.semitones,
				k.transposition.degrees,
				k.rate,
				e.beat,
			),
			i32(r.x) + 12,
			i32(r.y) + 32,
			14,
			rl.LIGHTGRAY,
		)
	}
}


// Side-routed arrow: connects the same edge (left or right) of two
// cells in the column. The chord is vertical, so the curve bows out
// horizontally — left for sibling arrows, right for `first`. Magnitude
// scales with vertical distance so longer jumps swing wider.
@(private = "file")
debug_draw_side_arrow :: proc(
	from, to: rl.Rectangle,
	color: rl.Color,
	right_side: bool,
	bidirectional: bool,
) {
	a, b: rl.Vector2
	if right_side {
		a = rl.Vector2{from.x + from.width, from.y + from.height * 0.5}
		b = rl.Vector2{to.x + to.width, to.y + to.height * 0.5}
	} else {
		a = rl.Vector2{from.x, from.y + from.height * 0.5}
		b = rl.Vector2{to.x, to.y + to.height * 0.5}
	}

	dy := b.y - a.y
	L := abs(dy)
	if L < 1 do return

	arc := clamp(L * 0.45, 30, 240)
	side: f32 = right_side ? 1 : -1
	arc_x := side * arc

	along := dy * 0.25
	c1 := rl.Vector2{a.x + arc_x, a.y + along}
	c2 := rl.Vector2{b.x + arc_x, b.y - along}

	rl.DrawSplineSegmentBezierCubic(a, c1, c2, b, 2.5, color)

	debug_draw_head(a, c1, c2, b, color, false)
	if bidirectional do debug_draw_head(a, c1, c2, b, color, true)
}


// Place an arrowhead on the cubic Bezier (a, c1, c2, b), oriented along
// the curve's tangent at the chosen end. `at_start` puts the head at
// `a` instead of `b`.
@(private = "file")
debug_draw_head :: proc(a, c1, c2, b: rl.Vector2, color: rl.Color, at_start: bool) {
	HEAD_LEN :: f32(14)
	HEAD_W :: f32(9)

	tip: rl.Vector2
	near: rl.Vector2
	if at_start {
		tip = a
		near = rl.GetSplinePointBezierCubic(a, c1, c2, b, 0.08)
	} else {
		tip = b
		near = rl.GetSplinePointBezierCubic(a, c1, c2, b, 0.92)
	}

	tx := tip.x - near.x
	ty := tip.y - near.y
	tlen := math.sqrt(tx * tx + ty * ty)
	if tlen < 0.001 do return
	tx /= tlen
	ty /= tlen
	hpx := -ty
	hpy := tx

	base := rl.Vector2{tip.x - tx * HEAD_LEN, tip.y - ty * HEAD_LEN}
	p1 := rl.Vector2{base.x + hpx * HEAD_W, base.y + hpy * HEAD_W}
	p2 := rl.Vector2{base.x - hpx * HEAD_W, base.y - hpy * HEAD_W}
	rl.DrawTriangle(tip, p2, p1, color)
}


// Vertical scrollbar pinned to the right edge of the area, only drawn
// when there's actually content to scroll past.
@(private = "file")
debug_draw_scrollbar :: proc(area: rl.Rectangle, total_h, max_scroll: f32) {
	if max_scroll <= 0 do return

	BAR_W :: f32(4)
	track_x := area.x + area.width - BAR_W - 4
	track := rl.Rectangle{track_x, area.y + 4, BAR_W, area.height - 8}
	rl.DrawRectangleRec(track, rl.Color{40, 40, 52, 200})

	visible_frac := area.height / total_h
	thumb_h := max(20, track.height * visible_frac)
	thumb_y := track.y + (track.height - thumb_h) * (debug_scroll / max_scroll)
	thumb := rl.Rectangle{track.x, thumb_y, BAR_W, thumb_h}
	rl.DrawRectangleRec(thumb, rl.Color{120, 120, 150, 230})
}


@(private = "file")
debug_draw_legend :: proc(area: rl.Rectangle, sibling_c, first_c: rl.Color) {
	x := i32(area.x + 12)
	y := i32(area.y + 10)
	ui_draw_text("⇄ prev/next", x, y, 13, sibling_c)
	ui_draw_text("→ first", x, y + 18, 13, first_c)
}
