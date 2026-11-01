package core

Window_Metrics :: struct {
	logical_w, logical_h: f32, // the size the UI is laid out for
	fb_w, fb_h:           i32,
	scale:                f32, // physical pixels per logical pixel
	input_scale:          f32, // logical pixels per window coordinate
}
