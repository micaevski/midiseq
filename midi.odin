package main

import "core:c"
import "core:fmt"
import "core:strings"
import pm "vendor:portmidi"
import "seq"


// Midi_Out owns the MIDI output stream and the (channel, key) reference
// counts. Callers just call midi_note_on / midi_note_off; overlapping
// holds on the same (channel, key) coalesce into a single physical
// note-on/note-off pair.
Midi_Out :: struct {
	stream:     pm.Stream,
	key_counts: [16][128]i32,
}


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

midi_close :: proc(midi: ^Midi_Out) {
	pm.Close(midi.stream)
	pm.Terminate()
}

// Adaptor: wrap this Midi_Out as a seq.Sink the sequencer can emit through.
midi_sink :: proc(midi: ^Midi_Out) -> seq.Sink {
	on :: proc(user: rawptr, channel, number, velocity: i32) {
		midi_note_on(cast(^Midi_Out)user, channel, number, velocity)
	}
	off :: proc(user: rawptr, channel, number: i32) {
		midi_note_off(cast(^Midi_Out)user, channel, number)
	}
	return seq.Sink{user = midi, note_on = on, note_off = off}
}

midi_note_on :: proc(midi: ^Midi_Out, channel, number, velocity: i32) {
	if channel < 0 || channel >= 16 do return
	if number < 0 || number >= 128 do return
	count := &midi.key_counts[channel][number]
	count^ += 1
	if count^ == 1 {
		pm.WriteShort(
			midi.stream,
			0,
			pm.MessageMake(0x90 | c.int(channel), c.int(number), c.int(velocity)),
		)
	}
}

// Emit note-off for every (channel, key) that still has a held count.
// Used to flush the output when the sequencer is torn down or killed.
midi_all_notes_off :: proc(midi: ^Midi_Out) {
	for channel: i32 = 0; channel < 16; channel += 1 {
		for number: i32 = 0; number < 128; number += 1 {
			if midi.key_counts[channel][number] > 0 {
				pm.WriteShort(
					midi.stream,
					0,
					pm.MessageMake(0x80 | c.int(channel), c.int(number), 0),
				)
				midi.key_counts[channel][number] = 0
			}
		}
	}
}

midi_note_off :: proc(midi: ^Midi_Out, channel, number: i32) {
	if channel < 0 || channel >= 16 do return
	if number < 0 || number >= 128 do return
	count := &midi.key_counts[channel][number]
	if count^ <= 0 do return
	count^ -= 1
	if count^ == 0 {
		pm.WriteShort(midi.stream, 0, pm.MessageMake(0x80 | c.int(channel), c.int(number), 0))
	}
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
