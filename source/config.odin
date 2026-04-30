package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"


CONFIG_PATH :: "midiseq.config"
DEFAULT_TEMPO :: f32(120)

Config :: struct {
	midi_in:        [MIDI_NAME_LEN]u8,
	midi_out:       [MIDI_NAME_LEN]u8,
	tempo:          f32,
	external_clock: bool,
}


config_in :: proc(c: ^Config) -> string {
	n := 0
	for n < MIDI_NAME_LEN && c.midi_in[n] != 0 do n += 1
	return string(c.midi_in[:n])
}

config_out :: proc(c: ^Config) -> string {
	n := 0
	for n < MIDI_NAME_LEN && c.midi_out[n] != 0 do n += 1
	return string(c.midi_out[:n])
}

config_set_in :: proc(c: ^Config, name: string) {
	c.midi_in = {}
	n := min(len(name), MIDI_NAME_LEN - 1)
	for i in 0 ..< n do c.midi_in[i] = name[i]
}

config_set_out :: proc(c: ^Config, name: string) {
	c.midi_out = {}
	n := min(len(name), MIDI_NAME_LEN - 1)
	for i in 0 ..< n do c.midi_out[i] = name[i]
}


// Read midiseq.config (key = value text, one entry per line) into the
// passed-in Config. Missing file or unreadable lines silently leave
// the corresponding fields empty. Uses temp_allocator for the file
// read; the caller is expected to free_all(temp_allocator) per frame.
config_load :: proc(c: ^Config, path: string) -> bool {
	c^ = {}
	c.tempo = DEFAULT_TEMPO
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil do return false
	text := string(data)
	for {
		line, more := next_line(&text)
		if !more do break
		eq := strings.index_byte(line, '=')
		if eq < 0 do continue
		key := strings.trim_space(line[:eq])
		value := strings.trim_space(line[eq + 1:])
		switch key {
		case "midi_in":
			config_set_in(c, value)
		case "midi_out":
			config_set_out(c, value)
		case "tempo":
			if v, ok := strconv.parse_f32(value); ok do c.tempo = v
		case "external_clock":
			c.external_clock = value == "true" || value == "1"
		}
	}
	return true
}

// Serialize the Config to disk. Builds the text into a stack buffer
// to avoid any heap allocation.
config_save :: proc(c: ^Config, path: string) -> bool {
	buf: [MIDI_NAME_LEN * 4 + 128]u8
	ext: cstring = c.external_clock ? "true" : "false"
	text := fmt.bprintf(
		buf[:],
		"midi_in = %s\nmidi_out = %s\ntempo = %.2f\nexternal_clock = %s\n",
		config_in(c),
		config_out(c),
		c.tempo,
		ext,
	)
	return os.write_entire_file(path, transmute([]u8)text) == nil
}


@(private = "file")
next_line :: proc(s: ^string) -> (line: string, ok: bool) {
	if len(s^) == 0 do return "", false
	rest := s^
	nl := strings.index_byte(rest, '\n')
	if nl < 0 {
		line = rest
		s^ = ""
	} else {
		line = rest[:nl]
		s^ = rest[nl + 1:]
	}
	if len(line) > 0 && line[len(line) - 1] == '\r' do line = line[:len(line) - 1]
	return line, true
}
