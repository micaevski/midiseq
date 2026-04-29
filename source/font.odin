package main

import rl "vendor:raylib"


// Single TTF font shared by everything we draw. Loaded oversized at
// FONT_LOAD_SIZE so smaller render sizes downscale via bilinear instead
// of aliasing like the default raylib bitmap font.
@(private = "file")
ui_font: rl.Font

@(private = "file")
ui_font_loaded: bool


@(private = "file")
FONT_LOAD_SIZE :: i32(32)


// Try a few common macOS TTF paths in order. Falls back to raylib's
// default font if none load.
load_ui_font :: proc() {
	candidates := []cstring {
		"/System/Library/Fonts/Supplemental/Arial.ttf",
		"/System/Library/Fonts/Monaco.ttf",
		"/System/Library/Fonts/SFCompact.ttf",
	}
	for path in candidates {
		f := rl.LoadFontEx(path, FONT_LOAD_SIZE, nil, 0)
		if f.texture.id != 0 && f.glyphCount > 0 {
			rl.SetTextureFilter(f.texture, .BILINEAR)
			ui_font = f
			ui_font_loaded = true
			return
		}
	}
	ui_font = rl.GetFontDefault()
}

unload_ui_font :: proc() {
	if ui_font_loaded do rl.UnloadFont(ui_font)
}

ui_draw_text :: proc(text: cstring, x, y: i32, size: i32, color: rl.Color) {
	rl.DrawTextEx(ui_font, text, rl.Vector2{f32(x), f32(y)}, f32(size), 0, color)
}

ui_measure_text :: proc(text: cstring, size: i32) -> i32 {
	return i32(rl.MeasureTextEx(ui_font, text, f32(size), 0).x)
}
