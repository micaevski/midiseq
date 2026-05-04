package main

import "seq"


App :: struct {
	midi: ^Midi_IO,
	vis:  ^Vis_State,
}


app_sink :: proc(app: ^App) -> seq.Sink {
	note_on :: proc(user: rawptr, channel, number, velocity: i32, beat: f32) {
		app := cast(^App)(cast(^seq.Sink)user).user
		midi_send_note_on(app.midi, channel, number, velocity)
	}
	note_off :: proc(user: rawptr, channel, number: i32, beat: f32) {
		app := cast(^App)(cast(^seq.Sink)user).user
		midi_send_note_off(app.midi, channel, number)
	}
	cc :: proc(user: rawptr, channel, number, value: i32, beat: f32) {
		app := cast(^App)(cast(^seq.Sink)user).user
		midi_send_cc(app.midi, channel, number, value)
	}
	on_spawn :: proc(
		user: rawptr,
		parent_rt_idx, rt_idx: seq.Runtime_Index,
		ev: seq.Runtime_Event,
		beat: f32,
		note_velocity: i32,
	) {
		app := cast(^App)(cast(^seq.Sink)user).user
		vis_handle_spawn(app.vis, parent_rt_idx, rt_idx, ev, beat, note_velocity)
	}
	on_retire :: proc(user: rawptr, rt_idx: seq.Runtime_Index, beat: f32) {
		app := cast(^App)(cast(^seq.Sink)user).user
		vis_handle_retire(app.vis, rt_idx)
	}
	on_reset :: proc(user: rawptr) {
		app := cast(^App)(cast(^seq.Sink)user).user
		vis_clear(app.vis)
	}
	return seq.Sink {
		user = app,
		note_on = note_on,
		note_off = note_off,
		cc = cc,
		on_spawn = on_spawn,
		on_retire = on_retire,
		on_reset = on_reset,
	}
}
