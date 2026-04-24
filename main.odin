package main

import "core:time"


SOURCE :: `
A = [
    (0, 0.4, (60, 100)),
    (0.5, 0.4, (62, 100)),
    (1, 0.4, (64, 100)),
    (1.5, 0.4, (67, 100))
]

B = [
    (0, 2, A),
    (2, 2, A)
]
`


main :: proc() {
	midi: Midi_Out
	if !midi_open(&midi) do return
	defer midi_close(&midi)

	sequencer := make_sequencer()
	defer destroy_sequencer(&sequencer)
	sequencer.midi = &midi
	sequencer.tempo = 120

	root, ok := parse_source(&sequencer, SOURCE)
	if !ok do return
	sequencer.root = root

	start_sequencer(&sequencer)

	total_duration := pool_get(&sequencer.pool, sequencer.root).duration

	last := time.now()
	for sequencer.beat < total_duration {
		now := time.now()
		dt := f32(time.duration_seconds(time.diff(last, now)))
		last = now
		sequencer_tick(&sequencer, dt)
		time.sleep(1 * time.Millisecond)
	}

	time.sleep(100 * time.Millisecond)
}
