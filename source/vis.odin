package main

import "core:fmt"
import "seq"
import rl "vendor:raylib"


Vis_Index :: distinct u32
NIL_VIS :: Vis_Index(0)

VIS_NODE_W :: f32(260)
VIS_NODE_H :: f32(108)
VIS_X_GAP :: f32(28)
VIS_Y_GAP :: f32(10)


Vis_Node :: struct {
	parent:        Vis_Index,
	first_child:   Vis_Index,
	next_sibling:  Vis_Index,
	retired:       bool,
	rt_idx:        seq.Runtime_Index,
	snapshot:      seq.Runtime_Event,
	spawn_beat:    f32,
	note_velocity: i32,
}


Vis_State :: struct {
	storage:        []Vis_Node,
	count:          u32,
	free_head:      Vis_Index,
	in_use:         u32,
	rt_to_vis:      []Vis_Index,
	roots:          [dynamic]Vis_Index,
	pool_exhausted: bool,
	scroll:         rl.Vector2,
}


vis_init :: proc(v: ^Vis_State, capacity: int, runtime_capacity: int) {
	v.storage = make([]Vis_Node, capacity + 1)
	v.count = 1
	v.free_head = NIL_VIS
	v.in_use = 0
	v.rt_to_vis = make([]Vis_Index, runtime_capacity + 1)
	v.roots = make([dynamic]Vis_Index, 0, 32)
}


vis_destroy :: proc(v: ^Vis_State) {
	delete(v.storage)
	delete(v.rt_to_vis)
	delete(v.roots)
}


vis_clear :: proc(v: ^Vis_State) {
	v.count = 1
	v.free_head = NIL_VIS
	v.in_use = 0
	for &slot in v.rt_to_vis do slot = NIL_VIS
	clear(&v.roots)
	v.pool_exhausted = false
}


@(private = "file")
vis_alloc :: proc(v: ^Vis_State) -> Vis_Index {
	if v.free_head != NIL_VIS {
		idx := v.free_head
		v.free_head = v.storage[idx].parent
		v.storage[idx] = {}
		v.in_use += 1
		return idx
	}
	if int(v.count) >= len(v.storage) do return NIL_VIS
	idx := Vis_Index(v.count)
	v.count += 1
	v.storage[idx] = {}
	v.in_use += 1
	return idx
}


@(private = "file")
vis_free :: proc(v: ^Vis_State, idx: Vis_Index) {
	if idx == NIL_VIS do return
	v.storage[idx].parent = v.free_head
	v.free_head = idx
	v.in_use -= 1
}


vis_handle_spawn :: proc(
	v: ^Vis_State,
	parent_rt_idx, rt_idx: seq.Runtime_Index,
	ev: seq.Runtime_Event,
	beat: f32,
	note_velocity: i32,
) {
	new_idx := vis_alloc(v)
	if new_idx == NIL_VIS {
		v.pool_exhausted = true
		return
	}
	parent_vis: Vis_Index = NIL_VIS
	if parent_rt_idx != seq.NIL_RUNTIME && int(parent_rt_idx) < len(v.rt_to_vis) {
		parent_vis = v.rt_to_vis[u32(parent_rt_idx)]
	}
	node := &v.storage[new_idx]
	node.parent = parent_vis
	node.first_child = NIL_VIS
	node.next_sibling = NIL_VIS
	node.retired = false
	node.rt_idx = rt_idx
	node.snapshot = ev
	node.spawn_beat = beat
	node.note_velocity = note_velocity

	if parent_vis != NIL_VIS {
		p := &v.storage[parent_vis]
		node.next_sibling = p.first_child
		p.first_child = new_idx
	} else {
		append(&v.roots, new_idx)
	}
	if int(rt_idx) < len(v.rt_to_vis) {
		v.rt_to_vis[u32(rt_idx)] = new_idx
	}
}


vis_handle_retire :: proc(v: ^Vis_State, rt_idx: seq.Runtime_Index) {
	if int(rt_idx) >= len(v.rt_to_vis) do return
	vis_idx := v.rt_to_vis[u32(rt_idx)]
	if vis_idx == NIL_VIS do return
	v.rt_to_vis[u32(rt_idx)] = NIL_VIS
	v.storage[vis_idx].retired = true
	vis_try_clear(v, vis_idx)
}


@(private = "file")
vis_try_clear :: proc(v: ^Vis_State, idx: Vis_Index) {
	cur := idx
	for cur != NIL_VIS {
		node := &v.storage[cur]
		if !node.retired || node.first_child != NIL_VIS do return
		parent := node.parent
		next_sibling := node.next_sibling
		if parent != NIL_VIS {
			p := &v.storage[parent]
			if p.first_child == cur {
				p.first_child = next_sibling
			} else {
				walker := p.first_child
				for walker != NIL_VIS {
					w := &v.storage[walker]
					if w.next_sibling == cur {
						w.next_sibling = next_sibling
						break
					}
					walker = w.next_sibling
				}
			}
		} else {
			for i in 0 ..< len(v.roots) {
				if v.roots[i] == cur {
					ordered_remove(&v.roots, i)
					break
				}
			}
		}
		vis_free(v, cur)
		cur = parent
	}
}


vis_draw :: proc(v: ^Vis_State, sequencer: seq.Sequencer_Handle, area: rl.Rectangle) {
	rl.DrawRectangleRec(area, rl.Color{12, 12, 18, 255})
	rl.BeginScissorMode(i32(area.x), i32(area.y), i32(area.width), i32(area.height))
	defer rl.EndScissorMode()

	mouse := rl.GetMousePosition()
	hovered := rl.CheckCollisionPointRec(mouse, area)
	if hovered {
		wheel := rl.GetMouseWheelMoveV()
		v.scroll.x += wheel.x * 30
		v.scroll.y += wheel.y * 30
		if rl.IsMouseButtonDown(.RIGHT) {
			delta := rl.GetMouseDelta()
			v.scroll.x += delta.x
			v.scroll.y += delta.y
		}
	}
	if v.scroll.x > 0 do v.scroll.x = 0
	if v.scroll.y > 0 do v.scroll.y = 0

	origin_x := area.x + 12 + v.scroll.x
	cur_y := area.y + 12 + v.scroll.y
	for root in v.roots {
		bottom := vis_draw_subtree(v, sequencer, root, origin_x, cur_y)
		cur_y = bottom + VIS_Y_GAP * 2
	}

	if v.pool_exhausted {
		ui_draw_text(
			"vis pool exhausted",
			i32(area.x) + 12,
			i32(area.y + area.height) - 24,
			14,
			rl.Color{220, 120, 120, 255},
		)
	}
}


@(private = "file")
vis_draw_subtree :: proc(v: ^Vis_State, sequencer: seq.Sequencer_Handle, idx: Vis_Index, x, y: f32) -> f32 {
	node := &v.storage[idx]
	vis_draw_node(node, sequencer, x, y)

	cur_y := y
	next_x := x + VIS_NODE_W + VIS_X_GAP
	child := node.first_child
	for child != NIL_VIS {
		c := &v.storage[child]
		next_sibling := c.next_sibling
		rl.DrawLineEx(
			rl.Vector2{x + VIS_NODE_W, y + VIS_NODE_H / 2},
			rl.Vector2{next_x, cur_y + VIS_NODE_H / 2},
			1.5,
			rl.Color{100, 100, 130, 200},
		)
		bottom := vis_draw_subtree(v, sequencer, child, next_x, cur_y)
		cur_y = bottom + VIS_Y_GAP
		child = next_sibling
	}
	return max(y + VIS_NODE_H, cur_y - VIS_Y_GAP)
}


@(private = "file")
vis_draw_node :: proc(node: ^Vis_Node, sequencer: seq.Sequencer_Handle, x, y: f32) {
	rect := rl.Rectangle{x, y, VIS_NODE_W, VIS_NODE_H}

	bg := rl.Color{30, 30, 42, 230}
	border := rl.Color{80, 80, 100, 255}
	label_col := rl.Color{200, 200, 220, 255}
	label, line2, line3, line4: cstring

	switch k in node.snapshot.kind {
	case seq.Runtime_Note:
		label_col = rl.Color{180, 220, 255, 255}
		parent_name := seq.sequencer_name(sequencer, k.parent_source_idx)
		if len(parent_name) > 0 {
			label = fmt.ctprintf("%s : %d", parent_name, k.number)
		} else {
			label = fmt.ctprintf("note %d", k.number)
		}
		line2 = fmt.ctprintf("ch %d  vel %d", k.channel + 1, node.note_velocity)
		line3 = fmt.ctprintf("dur %.2f", k.duration)
		line4 = fmt.ctprintf("b %.2f", node.spawn_beat)
	case seq.Runtime_Timeline:
		label_col = rl.Color{200, 180, 255, 255}
		name := seq.sequencer_name(sequencer, k.source_idx)
		if len(name) == 0 do name = "timeline"
		label = fmt.ctprintf("%s  ch %d", name, k.channel + 1)
		line2 = fmt.ctprintf("vel %d   trans %d / %dd", k.velocity, k.transposition.semitones, k.transposition.degrees)
		line3 = fmt.ctprintf("rate %.2f   mod %d %d %d %d", k.rate, k.mods[0], k.mods[1], k.mods[2], k.mods[3])
		line4 = fmt.ctprintf("b %.2f", node.spawn_beat)
	}
	if node.retired {
		bg = rl.Color{28, 22, 22, 200}
		border = rl.Color{90, 60, 60, 255}
		label_col.r = u8(i32(label_col.r) * 7 / 10)
		label_col.g = u8(i32(label_col.g) * 7 / 10)
		label_col.b = u8(i32(label_col.b) * 7 / 10)
	}

	rl.DrawRectangleRounded(rect, 0.16, 6, bg)
	rl.DrawRectangleRoundedLinesEx(rect, 0.16, 6, 1.5, border)
	ui_draw_text(label, i32(x) + 12, i32(y) + 10, 18, label_col)
	if line2 != nil do ui_draw_text(line2, i32(x) + 12, i32(y) + 36, 14, rl.Color{190, 190, 210, 255})
	if line3 != nil do ui_draw_text(line3, i32(x) + 12, i32(y) + 58, 14, rl.Color{170, 200, 170, 255})
	if line4 != nil do ui_draw_text(line4, i32(x) + 12, i32(y) + 82, 13, rl.Color{160, 160, 180, 255})
}
