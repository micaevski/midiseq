package seq


// One sounding note read out of a Standard MIDI File. Beats are
// PPQ-relative (independent of any tempo meta events in the file).
Midi_Note :: struct {
	number:     i32,
	velocity:   i32,
	start_beat: f32,
	duration:   f32,
}


// Parse SMF format-0 or format-1 bytes. Walks every track, pairs each
// note-on with its matching note-off (or note-on velocity 0) on the
// same channel/pitch, and appends a Midi_Note for each completed pair.
// Tempo / time signature / SMPTE are ignored — beats come straight
// from `division` (PPQ). Pending note-ons that are never closed get
// dropped silently.
parse_midi_file :: proc(bytes: []byte) -> (notes: [dynamic]Midi_Note, ok: bool) {
	if len(bytes) < 14 do return
	if string(bytes[0:4]) != "MThd" do return

	header_len := read_be_u32(bytes[4:8])
	if header_len < 6 || 8 + int(header_len) > len(bytes) do return

	format := read_be_u16(bytes[8:10])
	ntrks := read_be_u16(bytes[10:12])
	division := read_be_u16(bytes[12:14])

	if format > 1 do return // format 2 (independent tracks) not supported
	if division & 0x8000 != 0 do return // SMPTE division not supported
	if division == 0 do return

	ppq := f32(division)

	notes = make([dynamic]Midi_Note)
	pos := 8 + int(header_len)

	Pending :: struct {
		start_tick: u32,
		velocity:   i32,
		active:     bool,
	}
	pending: [16][128]Pending

	for _ in 0 ..< int(ntrks) {
		if pos + 8 > len(bytes) {
			delete(notes)
			return nil, false
		}
		if string(bytes[pos:pos + 4]) != "MTrk" {
			delete(notes)
			return nil, false
		}
		track_len := read_be_u32(bytes[pos + 4:pos + 8])
		track_end := pos + 8 + int(track_len)
		if track_end > len(bytes) {
			delete(notes)
			return nil, false
		}
		pos += 8

		// Reset pending state per track — notes don't cross tracks.
		for c in 0 ..< 16 do for p in 0 ..< 128 do pending[c][p].active = false

		cur_tick := u32(0)
		running_status: u8 = 0

		for pos < track_end {
			delta, dt_consumed, ok_dt := read_vlq(bytes[pos:track_end])
			if !ok_dt {
				delete(notes)
				return nil, false
			}
			pos += dt_consumed
			cur_tick += delta

			if pos >= track_end {
				delete(notes)
				return nil, false
			}

			byte0 := bytes[pos]
			if byte0 >= 0x80 {
				running_status = byte0
				pos += 1
			}
			status := running_status
			if status < 0x80 {
				delete(notes)
				return nil, false
			}

			high := status & 0xF0
			chan := i32(status & 0x0F)

			switch high {
			case 0x80:
				// Note Off.
				if pos + 2 > track_end {
					delete(notes)
					return nil, false
				}
				pitch := bytes[pos]
				pos += 2 // skip pitch + release velocity
				if int(pitch) < 128 && pending[chan][pitch].active {
					pen := pending[chan][pitch]
					append(
						&notes,
						Midi_Note {
							number = i32(pitch),
							velocity = pen.velocity,
							start_beat = f32(pen.start_tick) / ppq,
							duration = f32(cur_tick - pen.start_tick) / ppq,
						},
					)
					pending[chan][pitch].active = false
				}
			case 0x90:
				// Note On (velocity 0 = Note Off).
				if pos + 2 > track_end {
					delete(notes)
					return nil, false
				}
				pitch := bytes[pos]
				vel := bytes[pos + 1]
				pos += 2
				if int(pitch) >= 128 do continue
				if vel == 0 {
					if pending[chan][pitch].active {
						pen := pending[chan][pitch]
						append(
							&notes,
							Midi_Note {
								number = i32(pitch),
								velocity = pen.velocity,
								start_beat = f32(pen.start_tick) / ppq,
								duration = f32(cur_tick - pen.start_tick) / ppq,
							},
						)
						pending[chan][pitch].active = false
					}
				} else {
					pending[chan][pitch] = Pending {
						start_tick = cur_tick,
						velocity   = i32(vel),
						active     = true,
					}
				}
			case 0xA0, 0xB0, 0xE0:
				pos += 2 // two data bytes
			case 0xC0, 0xD0:
				pos += 1 // one data byte
			case 0xF0:
				// System / meta: skip via VLQ length.
				if status == 0xFF {
					if pos >= track_end {
						delete(notes)
						return nil, false
					}
					pos += 1 // meta type
					meta_len, ml_consumed, ok_ml := read_vlq(bytes[pos:track_end])
					if !ok_ml {
						delete(notes)
						return nil, false
					}
					pos += ml_consumed + int(meta_len)
				} else if status == 0xF0 || status == 0xF7 {
					sx_len, sl_consumed, ok_sl := read_vlq(bytes[pos:track_end])
					if !ok_sl {
						delete(notes)
						return nil, false
					}
					pos += sl_consumed + int(sx_len)
				}
				// Running status is cleared after a system message.
				running_status = 0
			}
		}

		if pos != track_end {
			delete(notes)
			return nil, false
		}
	}

	return notes, true
}


@(private = "file")
read_be_u32 :: proc(b: []byte) -> u32 {
	return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])
}

@(private = "file")
read_be_u16 :: proc(b: []byte) -> u16 {
	return u16(b[0]) << 8 | u16(b[1])
}

// Read a Standard-MIDI variable-length quantity (up to 4 bytes;
// continuation bit is the MSB of each byte).
@(private = "file")
read_vlq :: proc(b: []byte) -> (val: u32, consumed: int, ok: bool) {
	val = 0
	for consumed < 4 && consumed < len(b) {
		c := b[consumed]
		consumed += 1
		val = (val << 7) | u32(c & 0x7F)
		if c & 0x80 == 0 do return val, consumed, true
	}
	return 0, 0, false
}
