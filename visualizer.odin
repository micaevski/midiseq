package main

import "core:fmt"
import "seq"
import rl "vendor:raylib"


// Flame-graph view of the runtime active chain. Each runtime event is a
// cell; cells stack vertically by `parent` depth and sit side-by-side
// among siblings. A parent's rectangle spans the full subtree width.
// State across frames is just scroll offsets — the node list is rebuilt
// each frame from the live active chain.
Visualizer :: struct {
	scroll_x: f32,
	scroll_y: f32,
}

destroy_visualizer :: proc(vis: ^Visualizer) {}

@(private = "file")
CELL_W :: f32(140)
@(private = "file")
CELL_H :: f32(46)
@(private = "file")
CELL_GAP_X :: f32(6)
@(private = "file")
CELL_GAP_Y :: f32(20)
@(private = "file")
PAD :: f32(20)
@(private = "file")
SCROLL_SPEED :: f32(40)


@(private = "file")
Flame_Node :: struct {
	runtime_idx: seq.Runtime_Index,
	children:    [dynamic]int, // indices into nodes
	subtree_w:   f32,
	x:           f32,
	depth:       int,
}


// Post-order: each node's subtree width is the max of its own min cell
// width and the total width of its children laid out in a row.
@(private = "file")
layout_subtree :: proc(nodes: ^[dynamic]Flame_Node, idx: int, depth: int) -> f32 {
	nodes[idx].depth = depth
	count := len(nodes[idx].children)
	if count == 0 {
		nodes[idx].subtree_w = CELL_W
		return CELL_W
	}
	total: f32 = 0
	for k in 0 ..< count {
		ci := nodes[idx].children[k]
		if k > 0 do total += CELL_GAP_X
		total += layout_subtree(nodes, ci, depth + 1)
	}
	w := max(CELL_W, total)
	nodes[idx].subtree_w = w
	return w
}


// Pre-order: place children left-to-right within the parent's allocated
// width. When the parent is wider than its children's combined width
// (because CELL_W floor exceeded child total), center them.
@(private = "file")
assign_x :: proc(nodes: ^[dynamic]Flame_Node, idx: int, left: f32) {
	nodes[idx].x = left
	count := len(nodes[idx].children)
	if count == 0 do return

	children_total: f32 = 0
	for k in 0 ..< count {
		ci := nodes[idx].children[k]
		if k > 0 do children_total += CELL_GAP_X
		children_total += nodes[ci].subtree_w
	}
	cur := left + (nodes[idx].subtree_w - children_total) * 0.5
	for k in 0 ..< count {
		ci := nodes[idx].children[k]
		if k > 0 do cur += CELL_GAP_X
		assign_x(nodes, ci, cur)
		cur += nodes[ci].subtree_w
	}
}


@(private = "file")
node_color :: proc(e: ^seq.Runtime_Event) -> rl.Color {
	palette := [?]rl.Color {
		{130, 180, 255, 230},
		{180, 255, 140, 230},
		{255, 200, 110, 230},
		{200, 160, 255, 230},
		{255, 120, 180, 230},
		{120, 220, 200, 230},
	}
	switch k in e.kind {
	case seq.Runtime_Note:
		return rl.Color{255, 170, 120, 235}
	case seq.Runtime_Timeline:
		return palette[int(k.source_idx) % len(palette)]
	}
	return rl.WHITE
}


draw_active :: proc(vis: ^Visualizer, sequencer: ^seq.Sequencer, area: rl.Rectangle, dt: f32) {
	rl.DrawRectangleRec(area, rl.Color{18, 18, 24, 255})

	// All scratch allocations in this frame go through the temp arena,
	// which main wipes once per loop iteration.
	context.allocator = context.temp_allocator

	nodes := make([dynamic]Flame_Node, 0, 64)
	rt_to_node := make(map[seq.Runtime_Index]int, 64)

	// Build node list from the active chain. The root timeline itself
	// is skipped — its children are reparented to NIL by play_timeline,
	// so they surface naturally as roots of the flame graph. Notes
	// whose runtime parent is NIL are also skipped: that covers both
	// notes spawned directly under root and notes orphaned mid-flight
	// (a `free` timeline ends or a loop jump retires their parent), so
	// the note doesn't pop into a sibling slot next to its grandparent.
	current := sequencer.active_head
	for current != seq.NIL_RUNTIME {
		e := seq.runtime_get(&sequencer.runtime_pool, current)
		skip := false
		switch k in e.kind {
		case seq.Runtime_Timeline:
			if k.source_idx == sequencer.source_root do skip = true
		case seq.Runtime_Note:
			if e.parent == seq.NIL_RUNTIME do skip = true
		}
		if !skip {
			rt_to_node[current] = len(nodes)
			append(&nodes, Flame_Node{runtime_idx = current})
		}
		current = e.active_next
	}

	if len(nodes) == 0 {
		return
	}

	// Wire children. Anything whose parent isn't in the live set
	// (root-skipped, or already retired) becomes its own root.
	roots := make([dynamic]int, 0, 8)
	for i in 0 ..< len(nodes) {
		e := seq.runtime_get(&sequencer.runtime_pool, nodes[i].runtime_idx)
		if e.parent == seq.NIL_RUNTIME {
			append(&roots, i)
		} else if pi, ok := rt_to_node[e.parent]; ok {
			append(&nodes[pi].children, i)
		} else {
			append(&roots, i)
		}
	}

	// Layout pass per root, packing roots horizontally.
	cur_x: f32 = 0
	for r, k in roots {
		if k > 0 do cur_x += CELL_GAP_X
		layout_subtree(&nodes, r, 0)
		assign_x(&nodes, r, cur_x)
		cur_x += nodes[r].subtree_w
	}

	max_depth := 0
	for i in 0 ..< len(nodes) {
		if nodes[i].depth > max_depth do max_depth = nodes[i].depth
	}

	total_w := PAD * 2 + cur_x
	total_h := PAD * 2 + f32(max_depth + 1) * CELL_H + f32(max_depth) * CELL_GAP_Y

	max_scroll_x := max(0, total_w - area.width)
	max_scroll_y := max(0, total_h - area.height)

	if rl.CheckCollisionPointRec(rl.GetMousePosition(), area) {
		// V-variant: trackpads/horizontal-wheel mice deliver both axes
		// natively; the scalar GetMouseWheelMove dominant-axis-collapses.
		wheel := rl.GetMouseWheelMoveV()
		vis.scroll_x -= wheel.x * SCROLL_SPEED
		vis.scroll_y -= wheel.y * SCROLL_SPEED
	}
	vis.scroll_x = clamp(vis.scroll_x, 0, max_scroll_x)
	vis.scroll_y = clamp(vis.scroll_y, 0, max_scroll_y)

	rl.BeginScissorMode(i32(area.x), i32(area.y), i32(area.width), i32(area.height))

	for i in 0 ..< len(nodes) {
		n := nodes[i]
		e := seq.runtime_get(&sequencer.runtime_pool, n.runtime_idx)
		cx := area.x + PAD + n.x - vis.scroll_x
		cy := area.y + PAD + f32(n.depth) * (CELL_H + CELL_GAP_Y) - vis.scroll_y
		cw := n.subtree_w
		ch := CELL_H

		if cx + cw < area.x || cx > area.x + area.width do continue
		if cy + ch < area.y || cy > area.y + area.height do continue

		rect := rl.Rectangle{cx, cy, cw, ch}
		rl.DrawRectangleRec(rect, node_color(e))
		rl.DrawRectangleLinesEx(rect, 1, rl.Color{20, 20, 30, 255})

		text: cstring
		switch k in e.kind {
		case seq.Runtime_Note:
			letter, octave := seq.note_number_split(k.number)
			text = fmt.ctprintf("%s%d", letter, octave)
		case seq.Runtime_Timeline:
			if name, has := sequencer.names.lookup[k.source_idx]; has {
				text = fmt.ctprintf("%s", name)
			} else {
				text = "timeline"
			}
		}
		ui_draw_text(text, i32(cx) + 8, i32(cy) + 14, 16, rl.Color{20, 20, 30, 255})
	}

	rl.EndScissorMode()

	draw_scrollbars(area, total_w, total_h, vis.scroll_x, vis.scroll_y, max_scroll_x, max_scroll_y)
}


@(private = "file")
draw_scrollbars :: proc(
	area: rl.Rectangle,
	total_w, total_h, scroll_x, scroll_y, max_x, max_y: f32,
) {
	BAR :: f32(4)
	track_col := rl.Color{40, 40, 52, 200}
	thumb_col := rl.Color{120, 120, 150, 230}

	if max_y > 0 {
		track := rl.Rectangle{area.x + area.width - BAR - 4, area.y + 4, BAR, area.height - 8}
		rl.DrawRectangleRec(track, track_col)
		thumb_h := max(20, track.height * (area.height / total_h))
		thumb_y := track.y + (track.height - thumb_h) * (scroll_y / max_y)
		rl.DrawRectangleRec(rl.Rectangle{track.x, thumb_y, BAR, thumb_h}, thumb_col)
	}
	if max_x > 0 {
		track := rl.Rectangle{area.x + 4, area.y + area.height - BAR - 4, area.width - 8, BAR}
		rl.DrawRectangleRec(track, track_col)
		thumb_w := max(20, track.width * (area.width / total_w))
		thumb_x := track.x + (track.width - thumb_w) * (scroll_x / max_x)
		rl.DrawRectangleRec(rl.Rectangle{thumb_x, track.y, thumb_w, BAR}, thumb_col)
	}
}
