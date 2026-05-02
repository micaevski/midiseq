package main

import "core:c"
import "core:fmt"
import "seq"
import pm "vendor:portmidi"


MAX_MIDI_DEVICES :: 32
MIDI_NAME_LEN :: 128
DROPDOWN_BUF_LEN :: 4096

@(private = "file")
RATE_HISTORY :: 60


// Snapshot of available PortMIDI devices, captured once at startup.
// Names are cstrings owned by PortMIDI, valid for the program's
// lifetime. Index 0 is reserved for a "(none)" sentinel.
Midi_Device :: struct {
	id:   pm.DeviceID,
	name: cstring,
}

Midi_Devices :: struct {
	in_count:     int,
	in_devices:   [MAX_MIDI_DEVICES]Midi_Device,
	in_dropdown:  [DROPDOWN_BUF_LEN]u8,
	out_count:    int,
	out_devices:  [MAX_MIDI_DEVICES]Midi_Device,
	out_dropdown: [DROPDOWN_BUF_LEN]u8,
}

// Thin wrapper around PortMIDI input + output streams. The sequencer
// owns all musical-time logic (overlap detection, throttling, runtime
// ownership); this layer just emits messages.
@(private = "file")
IN_BUF_LEN :: 128

Midi_IO :: struct {
	in_stream:       pm.Stream,
	out_stream:      pm.Stream,
	in_name:         [MIDI_NAME_LEN]u8,
	out_name:        [MIDI_NAME_LEN]u8,
	in_buf:          [IN_BUF_LEN]pm.Event,
	in_buf_count:    int,
	in_buf_pos:      int,
	events_in_frame: u32,
	rate_count_ring: [RATE_HISTORY]u32,
	rate_dt_ring:    [RATE_HISTORY]f32,
	rate_head:       u32,
	events_per_sec:  f32,
}


midi_init :: proc(devices: ^Midi_Devices) -> bool {
	if err := pm.Initialize(); err != .NoError {
		fmt.eprintln("Pm_Initialize failed:", pm.GetErrorText(err))
		return false
	}
	enumerate_devices(devices)
	return true
}

midi_terminate :: proc(midi: ^Midi_IO) {
	midi_close_input(midi)
	midi_close_output(midi)
	pm.Terminate()
}


@(private = "file")
enumerate_devices :: proc(devices: ^Midi_Devices) {
	devices^ = {}
	devices.in_devices[0] = Midi_Device {
		id   = pm.NoDevice,
		name = "(none)",
	}
	devices.in_count = 1
	devices.out_devices[0] = Midi_Device {
		id   = pm.NoDevice,
		name = "(none)",
	}
	devices.out_count = 1

	count := pm.CountDevices()
	for i in 0 ..< count {
		info := pm.GetDeviceInfo(pm.DeviceID(i))
		if info == nil do continue
		if info.input && devices.in_count < MAX_MIDI_DEVICES {
			devices.in_devices[devices.in_count] = Midi_Device {
				id   = pm.DeviceID(i),
				name = info.name,
			}
			devices.in_count += 1
		}
		if info.output && devices.out_count < MAX_MIDI_DEVICES {
			devices.out_devices[devices.out_count] = Midi_Device {
				id   = pm.DeviceID(i),
				name = info.name,
			}
			devices.out_count += 1
		}
	}

	build_dropdown(devices.in_devices[:devices.in_count], devices.in_dropdown[:])
	build_dropdown(devices.out_devices[:devices.out_count], devices.out_dropdown[:])
}

@(private = "file")
build_dropdown :: proc(devs: []Midi_Device, buf: []u8) {
	pos := 0
	for d, i in devs {
		if i > 0 && pos < len(buf) - 1 {
			buf[pos] = ';'
			pos += 1
		}
		s := string(d.name)
		for k in 0 ..< len(s) {
			if pos >= len(buf) - 1 do break
			buf[pos] = s[k]
			pos += 1
		}
	}
	buf[pos] = 0
}


midi_devices_find_in_index :: proc(devices: ^Midi_Devices, name: string) -> int {
	for i in 0 ..< devices.in_count {
		if string(devices.in_devices[i].name) == name do return i
	}
	return 0 // (none)
}

midi_devices_find_out_index :: proc(devices: ^Midi_Devices, name: string) -> int {
	for i in 0 ..< devices.out_count {
		if string(devices.out_devices[i].name) == name do return i
	}
	return 0 // (none)
}


midi_open_input_by_index :: proc(midi: ^Midi_IO, devices: ^Midi_Devices, idx: int) -> bool {
	midi_close_input(midi)
	if idx <= 0 || idx >= devices.in_count do return true
	d := devices.in_devices[idx]
	if err := pm.OpenInput(&midi.in_stream, d.id, nil, 128, nil, nil); err != .NoError {
		fmt.eprintln("OpenInput failed:", pm.GetErrorText(err))
		return false
	}
	store_name(&midi.in_name, string(d.name))
	return true
}

midi_open_output_by_index :: proc(midi: ^Midi_IO, devices: ^Midi_Devices, idx: int) -> bool {
	midi_close_output(midi)
	if idx <= 0 || idx >= devices.out_count do return true
	d := devices.out_devices[idx]
	if err := pm.OpenOutput(&midi.out_stream, d.id, nil, 128, nil, nil, 0); err != .NoError {
		fmt.eprintln("OpenOutput failed:", pm.GetErrorText(err))
		return false
	}
	store_name(&midi.out_name, string(d.name))
	return true
}

midi_close_input :: proc(midi: ^Midi_IO) {
	if midi.in_stream != nil {
		pm.Close(midi.in_stream)
		midi.in_stream = nil
	}
	midi.in_name = {}
	midi.in_buf_count = 0
	midi.in_buf_pos = 0
}


// Drain the next clock-relevant message from the input stream. Returns
// (event, data, true) for one message at a time; the caller loops until
// ok==false. Refills its internal buffer via Pm_Read on demand. Non-
// clock messages are dropped silently. SPP returns the 14-bit position
// (in 16th-notes) as `data`.
midi_read :: proc(midi: ^Midi_IO) -> (event: seq.Clock_Event, data: i32, ok: bool) {
	if midi.in_stream == nil do return .None, 0, false

	for {
		for midi.in_buf_pos < midi.in_buf_count {
			evt := midi.in_buf[midi.in_buf_pos]
			midi.in_buf_pos += 1
			msg := u32(evt.message)
			status := u8(msg & 0xFF)
			switch status {
			case 0xF8:
				return .Tick, 0, true
			case 0xFA:
				return .Start, 0, true
			case 0xFB:
				return .Continue, 0, true
			case 0xFC:
				return .Stop, 0, true
			case 0xF2:
				lsb := i32((msg >> 8) & 0x7F)
				msb := i32((msg >> 16) & 0x7F)
				return .Song_Position, (msb << 7) | lsb, true
			}
		}

		n := pm.Read(midi.in_stream, raw_data(midi.in_buf[:]), i32(len(midi.in_buf)))
		if n <= 0 do return .None, 0, false
		midi.in_buf_count = int(n)
		midi.in_buf_pos = 0
	}
}

midi_close_output :: proc(midi: ^Midi_IO) {
	if midi.out_stream != nil {
		pm.Close(midi.out_stream)
		midi.out_stream = nil
	}
	midi.out_name = {}
}


@(private = "file")
store_name :: proc(dst: ^[MIDI_NAME_LEN]u8, src: string) {
	dst^ = {}
	n := min(len(src), MIDI_NAME_LEN - 1)
	for i in 0 ..< n do dst[i] = src[i]
}

midi_in_name :: proc(midi: ^Midi_IO) -> string {
	n := 0
	for n < MIDI_NAME_LEN && midi.in_name[n] != 0 do n += 1
	return string(midi.in_name[:n])
}

midi_out_name :: proc(midi: ^Midi_IO) -> string {
	n := 0
	for n < MIDI_NAME_LEN && midi.out_name[n] != 0 do n += 1
	return string(midi.out_name[:n])
}


midi_end_frame :: proc(midi: ^Midi_IO, dt: f32) {
	when ODIN_DEBUG {
		midi.rate_count_ring[midi.rate_head] = midi.events_in_frame
		midi.rate_dt_ring[midi.rate_head] = dt
		midi.rate_head = (midi.rate_head + 1) % RATE_HISTORY
		midi.events_in_frame = 0

		sum_count: u32 = 0
		sum_dt: f32 = 0
		for i in 0 ..< RATE_HISTORY {
			sum_count += midi.rate_count_ring[i]
			sum_dt += midi.rate_dt_ring[i]
		}
		midi.events_per_sec = sum_dt > 0 ? f32(sum_count) / sum_dt : 0
	}
}


// Adaptor: wrap this Midi_IO as a seq.Sink the sequencer can emit through.
// "No output device open" is a normal state owned by this backend, so we
// silently drop the emit at the boundary; midi_note_on/off below assume
// a valid stream by construction.
midi_sink :: proc(midi: ^Midi_IO) -> seq.Sink {
	on :: proc(user: rawptr, channel, number, velocity: i32, beat: f32) {
		midi := cast(^Midi_IO)(cast(^seq.Sink)user).user
		if midi.out_stream == nil do return
		midi_note_on(midi, channel, number, velocity, beat)
	}
	off :: proc(user: rawptr, channel, number: i32, beat: f32) {
		midi := cast(^Midi_IO)(cast(^seq.Sink)user).user
		if midi.out_stream == nil do return
		midi_note_off(midi, channel, number, beat)
	}
	cc :: proc(user: rawptr, channel, number, value: i32, beat: f32) {
		midi := cast(^Midi_IO)(cast(^seq.Sink)user).user
		if midi.out_stream == nil do return
		midi_cc(midi, channel, number, value, beat)
	}
	return seq.Sink{user = midi, note_on = on, note_off = off, cc = cc}
}

midi_note_on :: proc(midi: ^Midi_IO, channel, number, velocity: i32, beat: f32) {
	pm.WriteShort(
		midi.out_stream,
		0,
		pm.MessageMake(0x90 | c.int(channel), c.int(number), c.int(velocity)),
	)
	midi.events_in_frame += 1
}

midi_note_off :: proc(midi: ^Midi_IO, channel, number: i32, beat: f32) {
	pm.WriteShort(midi.out_stream, 0, pm.MessageMake(0x80 | c.int(channel), c.int(number), 0))
	midi.events_in_frame += 1
}

midi_cc :: proc(midi: ^Midi_IO, channel, number, value: i32, beat: f32) {
	pm.WriteShort(
		midi.out_stream,
		0,
		pm.MessageMake(0xB0 | c.int(channel), c.int(number), c.int(value)),
	)
	midi.events_in_frame += 1
}
