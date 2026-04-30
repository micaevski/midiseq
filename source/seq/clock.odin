package seq


// =============================================================================
// Public API
// =============================================================================

Clock_Mode :: enum {
	Internal,
	External,
}

// Events the clock cares about. Other MIDI messages are filtered out
// at the source by midi_read before they reach clock_process_event.
Clock_Event :: enum {
	None,
	Tick, // 0xF8 timing clock
	Start, // 0xFA
	Continue, // 0xFB
	Stop, // 0xFC
	Song_Position, // 0xF2 (data carries 16th-note position)
}


// Opaque handle exported as the package's public clock type.
Clock_Handle :: ^Clock


// Snapshot of the clock's observable state. Inspect via `clock_status`.
Clock_Status :: struct {
	mode:    Clock_Mode,
	running: bool, // DAW says transport is running (always true in Internal)
	beat:    f32,
	tempo:   f32,
	bpm_ema: f32, // smoothed inferred tempo from MIDI clock pulses
}


make_clock :: proc(tempo: f32 = 120, mode: Clock_Mode = .Internal) -> Clock_Handle {
	c := new(Clock)
	c.tempo = tempo
	c.mode = mode
	return c
}

destroy_clock :: proc(c: Clock_Handle) {
	free(c)
}


clock_process_event :: proc(c: Clock_Handle, event: Clock_Event, data: i32, now: f64) {
	switch event {
	case .None:
	case .Tick:
		c.pulses += 1
		if c.last_pulse_t > 0 {
			interval := f32(now - c.last_pulse_t)
			if interval > 0 {
				bpm := 60.0 / (interval * 24)
				if c.bpm_ema == 0 do c.bpm_ema = bpm
				else do c.bpm_ema = c.bpm_ema * 0.9 + bpm * 0.1
			}
		}
		c.last_pulse_t = now
	case .Start:
		c.pulses = 0
		c.running = true
		c.beat = 0
	case .Continue:
		c.running = true
	case .Stop:
		c.running = false
	case .Song_Position:
		c.pulses = u32(data) * 6
		c.beat = f32(c.pulses) / 24.0
	}
}


clock_tick :: proc(c: Clock_Handle, dt: f32, playing: bool) {
	switch c.mode {
	case .Internal:
		if playing do c.beat += dt * c.tempo / 60.0
	case .External:
		c.beat = f32(c.pulses) / 24.0
		if c.bpm_ema > 0 do c.tempo = c.bpm_ema
	}
}


clock_is_running :: proc(c: Clock_Handle) -> bool {
	return c.mode == .Internal || c.running
}


clock_status :: proc(c: Clock_Handle) -> Clock_Status {
	return Clock_Status {
		mode = c.mode,
		running = c.running,
		beat = c.beat,
		tempo = c.tempo,
		bpm_ema = c.bpm_ema,
	}
}

clock_set_tempo :: proc(c: Clock_Handle, tempo: f32) {
	c.tempo = tempo
}

clock_set_mode :: proc(c: Clock_Handle, mode: Clock_Mode) {
	c.mode = mode
}


// =============================================================================
// Internals
// =============================================================================

// Clock owns the canonical beat and tempo. In internal mode the beat
// advances from dt × tempo. In external mode the beat is derived from
// MIDI clock pulses (PPQN = 24, so beat = pulses / 24).
@(private)
Clock :: struct {
	mode:         Clock_Mode,
	beat:         f32,
	tempo:        f32,
	pulses:       u32,
	running:      bool,
	last_pulse_t: f64,
	bpm_ema:      f32,
}
