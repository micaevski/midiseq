package main

import "core:fmt"
import "core:mem"
import "seq"
import rl "vendor:raylib"


VIS_FRAME_BYTES :: 1 * 1024 * 1024
MAX_VIS_CELLS :: 1024


@(private = "file")
ROW_H :: f32(22)
@(private = "file")
ROW_GAP :: f32(2)
@(private = "file")
PAD :: f32(20)
@(private = "file")
VIEWPORT_BEATS :: f32(16)
@(private = "file")
SHRINK_FRAMES :: u8(20)
@(private = "file")
CULL_FRAMES :: u32(120)
@(private = "file")
MAX_SLOTS :: 32


@(private = "file")
Vis_Cell :: struct {
	in_use:            bool,
	is_timeline:       bool,
	alive_this_frame:  bool,
	runtime_idx:       seq.Runtime_Index,
	parent_cell:       i16,
	slot_in_parent:    i16,
	def_idx:           seq.Source_Index,
	note_number:       i32,
	note_duration:     f32,
	spawn_beat:        f32,
	last_active_beat:  f32,
	last_active_frame: u32,
	target_extent:     i16,
	smoothed_extent:   i16,
	shrink_counter:    u8,
	y:                 f32,
}


Visualizer :: struct {
	frame:       mem.Arena,
	frame_buf:   []byte,
	cells:       [MAX_VIS_CELLS]Vis_Cell,
	frame_count: u32,
	scroll_y:    f32,
}


make_visualizer :: proc() -> Visualizer {
	v := Visualizer{}
	v.frame_buf = make([]byte, VIS_FRAME_BYTES)
	mem.arena_init(&v.frame, v.frame_buf)
	return v
}

destroy_visualizer :: proc(vis: ^Visualizer) {
	delete(vis.frame_buf)
	vis^ = {}
}


@(private = "file")
resolve_def_idx :: proc(sequencer: ^seq.Sequencer, source_idx: seq.Source_Index) -> seq.Source_Index {
	name, has := sequencer.names.lookup[source_idx]
	if !has do return source_idx
	if def, has2 := sequencer.names.by_name[name]; has2 do return def
	return source_idx
}


@(private = "file")
node_color :: proc(c: ^Vis_Cell) -> rl.Color {
	palette := [?]rl.Color {
		{130, 180, 255, 230},
		{180, 255, 140, 230},
		{255, 200, 110, 230},
		{200, 160, 255, 230},
		{255, 120, 180, 230},
		{120, 220, 200, 230},
	}
	if !c.is_timeline {
		return rl.Color{255, 170, 120, 235}
	}
	return palette[int(c.def_idx) % len(palette)]
}


@(private = "file")
find_alive_cell :: proc(vis: ^Visualizer, runtime_idx: seq.Runtime_Index) -> i16 {
	for i in 0 ..< MAX_VIS_CELLS {
		c := &vis.cells[i]
		if c.in_use && c.alive_this_frame && c.runtime_idx == runtime_idx {
			return i16(i)
		}
	}
	return -1
}


@(private = "file")
find_cell :: proc(
	vis: ^Visualizer,
	runtime_idx: seq.Runtime_Index,
	spawn_beat: f32,
) -> i16 {
	for i in 0 ..< MAX_VIS_CELLS {
		c := &vis.cells[i]
		if c.in_use && c.runtime_idx == runtime_idx && c.spawn_beat == spawn_beat {
			return i16(i)
		}
	}
	return -1
}


@(private = "file")
alloc_cell :: proc(vis: ^Visualizer) -> i16 {
	for i in 0 ..< MAX_VIS_CELLS {
		if !vis.cells[i].in_use {
			vis.cells[i] = Vis_Cell{}
			vis.cells[i].in_use = true
			return i16(i)
		}
	}
	return -1
}


@(private = "file")
parent_slot_heights :: proc(vis: ^Visualizer, parent_idx: i16) -> [MAX_SLOTS]i16 {
	heights: [MAX_SLOTS]i16
	for i in 0 ..< MAX_VIS_CELLS {
		c := &vis.cells[i]
		if !c.in_use || c.parent_cell != parent_idx do continue
		s := int(c.slot_in_parent)
		if s < 0 || s >= MAX_SLOTS do continue
		if c.smoothed_extent > heights[s] do heights[s] = c.smoothed_extent
	}
	return heights
}


@(private = "file")
sum_slots :: proc(vis: ^Visualizer, parent_idx: i16) -> i16 {
	heights := parent_slot_heights(vis, parent_idx)
	sum: i16 = 0
	for h in heights {
		sum += h
	}
	return sum
}


@(private = "file")
allocate_slot :: proc(
	vis: ^Visualizer,
	parent_idx: i16,
	is_timeline: bool,
	note_number: i32,
	source_idx: seq.Source_Index,
) -> i16 {
	if parent_idx < 0 do return 0
	for i in 0 ..< MAX_VIS_CELLS {
		c := &vis.cells[i]
		if !c.in_use || c.parent_cell != parent_idx do continue
		if c.is_timeline != is_timeline do continue
		if is_timeline && c.def_idx == source_idx do return c.slot_in_parent
		if !is_timeline && c.note_number == note_number do return c.slot_in_parent
	}
	max_slot: i16 = -1
	for i in 0 ..< MAX_VIS_CELLS {
		c := &vis.cells[i]
		if !c.in_use || c.parent_cell != parent_idx do continue
		if c.slot_in_parent > max_slot do max_slot = c.slot_in_parent
	}
	return max_slot + 1
}


@(private = "file")
find_reusable_cell :: proc(
	vis: ^Visualizer,
	parent_idx: i16,
	is_timeline: bool,
	note_number: i32,
	source_idx: seq.Source_Index,
) -> i16 {
	for i in 0 ..< MAX_VIS_CELLS {
		c := &vis.cells[i]
		if !c.in_use || c.alive_this_frame do continue
		if c.parent_cell != parent_idx do continue
		if c.is_timeline != is_timeline do continue
		if is_timeline && c.def_idx == source_idx do return i16(i)
		if !is_timeline && c.note_number == note_number do return i16(i)
	}
	return -1
}


@(private = "file")
has_in_use_children :: proc(vis: ^Visualizer, parent_idx: i16) -> bool {
	for i in 0 ..< MAX_VIS_CELLS {
		c := &vis.cells[i]
		if c.in_use && c.parent_cell == parent_idx do return true
	}
	return false
}


draw_active :: proc(vis: ^Visualizer, sequencer: ^seq.Sequencer, area: rl.Rectangle, dt: f32) {
	rl.DrawRectangleRec(area, rl.Color{18, 18, 24, 255})
	mem.arena_free_all(&vis.frame)
	context.allocator = mem.arena_allocator(&vis.frame)

	track_w := area.width - PAD * 2
	if track_w < 1 do return
	px_per_beat := track_w / VIEWPORT_BEATS
	viewport_start: f32 = 0
	if sequencer.beat > VIEWPORT_BEATS * 0.5 {
		viewport_start = sequencer.beat - VIEWPORT_BEATS * 0.5
	}

	vis.frame_count += 1

	for i in 0 ..< MAX_VIS_CELLS {
		vis.cells[i].alive_this_frame = false
	}

	current := sequencer.active_head
	for current != seq.NIL_RUNTIME {
		e := seq.runtime_get(&sequencer.runtime_pool, current)
		next := e.active_next

		skip := false
		switch k in e.kind {
		case seq.Runtime_Timeline:
			if k.source_idx == sequencer.source_root do skip = true
		case seq.Runtime_Note:
			if e.parent == seq.NIL_RUNTIME do skip = true
		}
		if skip {
			current = next
			continue
		}

		ci := find_cell(vis, current, e.beat)
		if ci < 0 {
			parent: i16 = e.parent != seq.NIL_RUNTIME ? find_alive_cell(vis, e.parent) : -1
			is_tl: bool
			note_num: i32
			note_dur: f32
			def_idx: seq.Source_Index
			switch k in e.kind {
			case seq.Runtime_Note:
				is_tl = false
				note_num = k.number
				note_dur = k.duration
			case seq.Runtime_Timeline:
				is_tl = true
				def_idx = resolve_def_idx(sequencer, k.source_idx)
			}

			ci = find_reusable_cell(vis, parent, is_tl, note_num, def_idx)
			if ci >= 0 {
				c := &vis.cells[ci]
				c.runtime_idx = current
				c.spawn_beat = e.beat
				if !is_tl do c.note_duration = note_dur
			} else {
				ci = alloc_cell(vis)
				if ci < 0 {
					current = next
					continue
				}
				c := &vis.cells[ci]
				c.runtime_idx = current
				c.spawn_beat = e.beat
				c.parent_cell = parent
				c.is_timeline = is_tl
				c.note_number = note_num
				c.note_duration = note_dur
				c.def_idx = def_idx
				c.slot_in_parent = allocate_slot(vis, parent, is_tl, note_num, def_idx)
			}
		}

		c := &vis.cells[ci]
		c.alive_this_frame = true
		c.last_active_beat = sequencer.beat
		c.last_active_frame = vis.frame_count
		current = next
	}

	for i in 0 ..< MAX_VIS_CELLS {
		c := &vis.cells[i]
		if !c.in_use do continue
		if !c.alive_this_frame &&
		   vis.frame_count - c.last_active_frame > CULL_FRAMES &&
		   !has_in_use_children(vis, i16(i)) {
			c.in_use = false
		}
	}

	for i := MAX_VIS_CELLS - 1; i >= 0; i -= 1 {
		c := &vis.cells[i]
		if !c.in_use do continue
		c.target_extent = 1 + sum_slots(vis, i16(i))
		if c.target_extent >= c.smoothed_extent {
			c.smoothed_extent = c.target_extent
			c.shrink_counter = 0
		} else {
			c.shrink_counter += 1
			if c.shrink_counter >= SHRINK_FRAMES {
				c.smoothed_extent = max(c.target_extent, c.smoothed_extent - 1)
				c.shrink_counter = 0
			}
		}
	}

	if rl.CheckCollisionPointRec(rl.GetMousePosition(), area) {
		wheel := rl.GetMouseWheelMoveV()
		vis.scroll_y -= wheel.y * 40
	}

	rl.BeginScissorMode(i32(area.x), i32(area.y), i32(area.width), i32(area.height))

	playhead_x := area.x + PAD + (sequencer.beat - viewport_start) * px_per_beat
	rl.DrawLineV(
		rl.Vector2{playhead_x, area.y},
		rl.Vector2{playhead_x, area.y + area.height},
		rl.Color{90, 200, 255, 220},
	)

	cur_top: f32 = area.y + PAD - vis.scroll_y
	for i in 0 ..< MAX_VIS_CELLS {
		c := &vis.cells[i]
		if !c.in_use || c.parent_cell != -1 do continue
		layout_subtree(vis, i16(i), cur_top)
		cur_top += f32(c.smoothed_extent) * (ROW_H + ROW_GAP)
	}

	for i in 0 ..< MAX_VIS_CELLS {
		c := &vis.cells[i]
		if !c.in_use do continue
		draw_cell(vis, c, sequencer, area, viewport_start, px_per_beat)
	}

	rl.EndScissorMode()
}


@(private = "file")
layout_subtree :: proc(vis: ^Visualizer, cell_idx: i16, y_top: f32) {
	c := &vis.cells[cell_idx]
	c.y = y_top
	heights := parent_slot_heights(vis, cell_idx)
	slot_y: [MAX_SLOTS]f32
	cur_y := y_top + (ROW_H + ROW_GAP)
	for s in 0 ..< MAX_SLOTS {
		slot_y[s] = cur_y
		cur_y += f32(heights[s]) * (ROW_H + ROW_GAP)
	}
	for i in 0 ..< MAX_VIS_CELLS {
		ch := &vis.cells[i]
		if !ch.in_use || ch.parent_cell != cell_idx do continue
		s := int(ch.slot_in_parent)
		if s < 0 || s >= MAX_SLOTS do continue
		ch.y = slot_y[s]
		if ch.is_timeline do layout_subtree(vis, i16(i), slot_y[s])
	}
}


@(private = "file")
draw_cell :: proc(
	vis: ^Visualizer,
	c: ^Vis_Cell,
	sequencer: ^seq.Sequencer,
	area: rl.Rectangle,
	viewport_start: f32,
	px_per_beat: f32,
) {
	x_start := area.x + PAD + (c.spawn_beat - viewport_start) * px_per_beat
	end_beat := c.alive_this_frame ? sequencer.beat : c.last_active_beat
	width := (end_beat - c.spawn_beat) * px_per_beat
	if width < 2 do width = 2
	x_end := x_start + width
	if x_end < area.x || x_start > area.x + area.width do return
	if c.y + ROW_H < area.y || c.y > area.y + area.height do return

	clip_left := x_start
	clip_right := x_end
	if clip_left < area.x + PAD do clip_left = area.x + PAD
	if clip_right > area.x + area.width - PAD do clip_right = area.x + area.width - PAD
	clip_w := clip_right - clip_left
	if clip_w < 1 do return

	col := node_color(c)
	if !c.alive_this_frame {
		frames_dead := vis.frame_count - c.last_active_frame
		t := 1.0 - f32(frames_dead) / f32(CULL_FRAMES)
		if t < 0 do t = 0
		col.a = u8(f32(col.a) * t)
	}
	rect := rl.Rectangle{clip_left, c.y, clip_w, ROW_H}
	rl.DrawRectangleRec(rect, col)
	rl.DrawRectangleLinesEx(rect, 1, rl.Color{20, 20, 30, 255})

	text: cstring
	if c.is_timeline {
		if name, has := sequencer.names.lookup[c.def_idx]; has {
			text = fmt.ctprintf("%s", name)
		} else {
			text = "timeline"
		}
	} else {
		letter, octave := seq.note_number_split(c.note_number)
		text = fmt.ctprintf("%s%d", letter, octave)
	}
	label_x := clip_left + 4
	if x_start > clip_left do label_x = x_start + 4
	ui_draw_text(text, i32(label_x), i32(c.y) + 4, 14, rl.Color{20, 20, 30, 255})
}
