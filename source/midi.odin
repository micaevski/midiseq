package main

import "core:c"
import "core:fmt"
import "core:strings"
import "seq"
import pm "vendor:portmidi"


// Thin wrapper around the PortMIDI output stream. The sequencer owns
// per-(channel, pitch) ownership and decides when a physical note-off
// is needed; this layer just emits messages, gated by a per-key
// musical-time throttle to keep MIDI volume under what the synth can
// drain.
Midi_Out :: struct {
	stream:          pm.Stream,
	last_emit_beat:  [16][128]f32,
	playing:         [16][128]bool,
	events_in_frame: u32,
	rate_count_ring: [RATE_HISTORY]u32,
	rate_dt_ring:    [RATE_HISTORY]f32,
	rate_head:       u32,
	events_per_sec:  f32,
}


@(private = "file")
RATE_HISTORY :: 60


THROTTLE_THRESHOLD :: seq.BEAT_QUANTUM

midi_open :: proc(midi: ^Midi_Out) -> bool {
	if err := pm.Initialize(); err != .NoError {
		fmt.eprintln("Pm_Initialize failed:", pm.GetErrorText(err))
		return false
	}

	device := pick_output_device()
	if device == pm.NoDevice {
		fmt.eprintln("No MIDI output device found. Launch SimpleSynth or fluidsynth first.")
		pm.Terminate()
		return false
	}

	if err := pm.OpenOutput(&midi.stream, device, nil, 128, nil, nil, 0); err != .NoError {
		fmt.eprintln("OpenOutput failed:", pm.GetErrorText(err))
		pm.Terminate()
		return false
	}

	return true
}

midi_reset :: proc(midi: ^Midi_Out) {
	midi.last_emit_beat = {}
	midi.playing = {}
}

midi_close :: proc(midi: ^Midi_Out) {
	if midi.stream != nil {
		pm.Close(midi.stream)
		midi.stream = nil
	}
	pm.Terminate()
}

midi_end_frame :: proc(midi: ^Midi_Out, dt: f32) {
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

// Adaptor: wrap this Midi_Out as a seq.Sink the sequencer can emit through.
// The sequencer passes the sink itself as the user pointer; we pull the
// owning Midi_Out back out of `sink.user`.
midi_sink :: proc(midi: ^Midi_Out) -> seq.Sink {
	on :: proc(user: rawptr, channel, number, velocity: i32, beat: f32) {
		sink := cast(^seq.Sink)user
		if sink == nil || sink.user == nil do return
		midi_note_on(cast(^Midi_Out)sink.user, channel, number, velocity, beat)
	}
	off :: proc(user: rawptr, channel, number: i32, beat: f32) {
		sink := cast(^seq.Sink)user
		if sink == nil || sink.user == nil do return
		midi_note_off(cast(^Midi_Out)sink.user, channel, number, beat)
	}
	return seq.Sink{user = midi, note_on = on, note_off = off}
}

midi_note_on :: proc(midi: ^Midi_Out, channel, number, velocity: i32, beat: f32) {
	if midi.stream == nil do return
	if channel < 0 || channel >= 16 do return
	if number < 0 || number >= 128 do return
	last := midi.last_emit_beat[channel][number]
	if beat <= last + THROTTLE_THRESHOLD do return
	pm.WriteShort(
		midi.stream,
		0,
		pm.MessageMake(0x90 | c.int(channel), c.int(number), c.int(velocity)),
	)
	midi.last_emit_beat[channel][number] = beat
	midi.playing[channel][number] = true
	when ODIN_DEBUG do midi.events_in_frame += 1
}

midi_note_off :: proc(midi: ^Midi_Out, channel, number: i32, beat: f32) {
	if midi.stream == nil do return
	if channel < 0 || channel >= 16 do return
	if number < 0 || number >= 128 do return
	if !midi.playing[channel][number] do return
	pm.WriteShort(midi.stream, 0, pm.MessageMake(0x80 | c.int(channel), c.int(number), 0))
	midi.playing[channel][number] = false
	when ODIN_DEBUG do midi.events_in_frame += 1
}


pick_output_device :: proc() -> pm.DeviceID {
	count := pm.CountDevices()
	fmt.println("MIDI devices:")
	for i in 0 ..< count {
		info := pm.GetDeviceInfo(pm.DeviceID(i))
		if info == nil do continue
		fmt.printfln(
			"  [%d] %s (%s) in=%v out=%v",
			i,
			info.name,
			info.interf,
			info.input,
			info.output,
		)
	}

	preferred := []string{"SimpleSynth", "FLUID", "fluid", "IAC"}
	for pref in preferred {
		for i in 0 ..< count {
			info := pm.GetDeviceInfo(pm.DeviceID(i))
			if info == nil || !info.output do continue
			if strings.contains(string(info.name), pref) {
				fmt.printfln("-> using: %s", info.name)
				return pm.DeviceID(i)
			}
		}
	}

	id := pm.GetDefaultOutputDeviceID()
	if id != pm.NoDevice {
		info := pm.GetDeviceInfo(id)
		fmt.printfln("-> using default output: %s", info.name)
	}
	return id
}
