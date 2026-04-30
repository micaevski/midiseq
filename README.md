# midiseq

Work in progress: a small text-based DSL for MIDI sequencing. Songs are
written as plain-text source that defines named timelines of notes and
references between them; the runtime parses the source, walks the
resulting tree against an internal or DAW-driven clock, and emits MIDI
to a chosen output device.

## Dependencies

- [Odin](https://odin-lang.org/) — install via the [Odin install guide](https://odin-lang.org/docs/install/).
- PortMIDI (via Odin's `vendor:portmidi`):
  `brew install portmidi` on macOS.
- Raylib ships with the Odin compiler (`vendor:raylib`); no extra install.

## Build & run

```
odin build source -out:build/midiseq -debug
./build/midiseq
```

Tests:

```
odin test tests -out:build/test
```
