package client

import "core:fmt"
import "core:sync"
import mu "vendor:microui"

import "client:conn"
import "client:platform"
import "client:settings"

// The settings' Screen sharing category: how we share (the size preset and,
// under Advanced, the frame rate, bitrate, encoder and pointer), and whether
// statistics are shown under the stream we watch. In a browser the browser
// shows the pointer or not, so that is desktop only, and the encoders are the
// browser's (conn/video_web.odin).
//
// What the server accepts from a sharer (its video.max_kbit) caps the bitrate,
// and this is said here when it does. Changes apply from the next share.
// Without the yap_video add-on there is nothing to set, so this says where to
// put the add-on instead (or, when it's there but found no FFmpeg, where FFmpeg
// comes from).
share_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	if platform.WEB && !conn.video_can_share() {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, theme.dim, "This browser can't share its screen.", wrap_text)
		mu.layout_row(ctx, {-1})
		if .CHANGE in
		   mu.checkbox(ctx, "Show screen share info below stream", &ui.settings.share_stats) {
			settings.settings_save(ui.opts.settings_path, ui.settings)
		}
		return
	}
	if !platform.WEB && !conn.video_can_watch() {
		mu.layout_row(ctx, {-1})
		text: string
		if conn.video_missing_ffmpeg() {
			text = fmt.tprintf(
				"Screen sharing needs FFmpeg 8 or 9, with H.264, and none was found. Install " +
				"FFmpeg from your system's packages, or put the FFmpeg libraries from the " +
				"yap-video download next to yap, in %s, and start yap again.",
				conn.video_library_dir(),
			)
		} else {
			text = fmt.tprintf(
				"Screen sharing needs yap's video add-on: the yap-video download that goes with " +
				"this build. Put what's in it next to yap, in %s, and start yap again.",
				conn.video_library_dir(),
			)
		}
		with_text_color(ctx, theme.dim, text, wrap_text)
		return
	}

	limit := 0
	{
		v := ui.view
		sync.guard(&v.mutex)
		limit = v.video_limit_kbit
	}
	cfg := conn.share_config(&ui.settings, limit)
	preset := conn.share_preset(&ui.settings)

	field_row(ui, 120, "Size", {CHOICE_WIDTH})
	sizes := make([]string, len(conn.SHARE_PRESETS), context.temp_allocator)
	for p, i in conn.SHARE_PRESETS {
		sizes[i] = p.label
	}
	if i, ok := choice_dropdown(ui, "share preset", sizes, preset); ok {
		settings.set_setting(&ui.settings.share_preset, conn.SHARE_PRESETS[i].name)
		settings.settings_save(ui.opts.settings_path, ui.settings)
	}
	mu.layout_row(ctx, {-1})
	size := "as big as it is"
	if cfg.max.x > 0 {
		size = fmt.tprintf("at most %dx%d", cfg.max.x, cfg.max.y)
	}
	held := ""
	if wanted := conn.share_config(&ui.settings, 0).kbit; wanted > cfg.kbit {
		held = fmt.tprintf(", as this server takes no more (%.1f asked for)", f64(wanted) / 1000)
	}
	with_text_color(
		ctx,
		theme.dim,
		fmt.tprintf(
			"Shares %s, at %d frames a second and %.1f Mbit/s%s.",
			size,
			cfg.fps,
			f64(cfg.kbit) / 1000,
			held,
		),
		wrap_text,
	)

	mu.layout_row(ctx, {-1})
	if mu.header(ctx, "Advanced") != {} {
		share_advanced(ui, cfg, limit)
	}

	mu.layout_row(ctx, {-1})
	with_text_color(ctx, theme.dim, "Changes apply the next time you start sharing.", wrap_text)

	mu.layout_row(ctx, {-1})
	if .CHANGE in
	   mu.checkbox(ctx, "Show screen share info below stream", &ui.settings.share_stats) {
		settings.settings_save(ui.opts.settings_path, ui.settings)
	}
}

// share_advanced is what changes about the preset: the frame rate, the
// bitrate, the encoder and the pointer.
@(private = "file")
share_advanced :: proc(ui: ^UI, cfg: conn.Share_Config, limit: int) {
	ctx := &ui.ctx
	vid := &ui.video

	field_row(ui, 120, "Frame rate", {CHOICE_WIDTH})
	fps_choices := conn.SHARE_FPS_CHOICES
	rates := make([]string, len(fps_choices), context.temp_allocator)
	rate_at := -1
	for fps, i in fps_choices {
		rates[i] = fmt.tprintf("%d fps", fps)
		if fps == cfg.fps {
			rate_at = i
		}
	}
	if i, ok := choice_dropdown(
		ui,
		"share fps",
		rates,
		rate_at,
		none = fmt.tprintf("%d fps", cfg.fps),
	); ok {
		ui.settings.share_fps = fps_choices[i]
		settings.settings_save(ui.opts.settings_path, ui.settings)
	}

	// Applied when the slider is released, like the UI scale.
	top := f32(limit if limit > 0 else conn.SHARE_KBIT_MAX)
	field_row(ui, 120, "Bitrate", {-120, 110})
	id := mu.get_id(ctx, uintptr(&vid.kbit_draft))
	dragging := ctx.focus_id == id
	if !dragging {
		vid.kbit_draft = f32(cfg.kbit)
	}
	mu.slider(ctx, &vid.kbit_draft, conn.SHARE_KBIT_MIN, top, 100, "%.0f kbit/s")
	if dragging && ctx.focus_id != id {
		ui.settings.share_kbit = int(vid.kbit_draft)
		settings.settings_save(ui.opts.settings_path, ui.settings)
	}
	if choice_button(ui, "share kbit preset", "The size's", ui.settings.share_kbit == 0) &&
	   ui.settings.share_kbit != 0 {
		ui.settings.share_kbit = 0
		settings.settings_save(ui.opts.settings_path, ui.settings)
	}

	// The best that works, or one picked: those that work here, and the one
	// picked before if it doesn't.
	encoders := conn.video_encoders()
	names := make([dynamic]string, context.temp_allocator)
	labels := make([dynamic]string, context.temp_allocator)
	append(&names, "")
	append(&labels, "The best that works")
	encoder_at := 0
	for e in encoders {
		if !e.works && e.name != cfg.encoder {
			continue
		}
		if e.name == cfg.encoder {
			encoder_at = len(names)
		}
		append(&names, e.name)
		append(&labels, e.label if e.works else fmt.tprintf("%s (doesn't work here)", e.label))
	}
	field_row(ui, 120, "Encoder", {-1})
	if i, ok := choice_dropdown(ui, "share encoder", labels[:], encoder_at); ok {
		settings.set_setting(&ui.settings.share_encoder, names[i])
		settings.settings_save(ui.opts.settings_path, ui.settings)
	}
	if encoders == nil {
		mu.layout_row(ctx, {120, -1})
		mu.label(ctx, "")
		with_text_color(ctx, theme.dim, "Still trying the encoders...", wrap_text)
		ui_redraw_in(ui, ANIMATION_FRAME * 15)
	}
	if cfg.encoder != "" && encoders != nil {
		// The best encoder that works keeps to what everyone in the room can
		// decode (conn/video.odin). A chosen encoder is used regardless.
		mu.layout_row(ctx, {120, -1})
		mu.label(ctx, "")
		with_text_color(ctx, theme.dim, "Viewers that can't decode it see nothing", wrap_text)
	}

	when platform.WEB {
		return
	}
	mu.layout_row(ctx, {-1})
	if .CHANGE in mu.checkbox(ctx, "Show the pointer", &ui.settings.share_cursor) {
		settings.settings_save(ui.opts.settings_path, ui.settings)
	}
}
