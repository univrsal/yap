package client

import "core:fmt"
import "core:sync"
import mu "vendor:microui"

import "client:conn"
import "client:platform"
import "client:settings"

// The settings' Screen sharing category, on the desktop: how we share (the
// size preset and, under Advanced, the frame rate, bitrate, encoder and
// pointer), and whether statistics are shown under the stream we watch. A
// browser shares what its own picker offers, so a web build has none of this.
//
// What the server accepts from a sharer (its video.max_kbit) caps the bitrate,
// and this is said here when it does. Changes apply from the next share.
// Without the yap_video add-on there is nothing to set, so this says where to
// put the add-on instead.
share_settings :: proc(ui: ^UI) {
	when platform.WEB {
		return
	}
	ctx := &ui.ctx
	if !conn.video_can_watch() {
		mu.layout_row(ctx, {-1})
		with_text_color(
			ctx,
			theme.dim,
			fmt.tprintf(
				"Screen sharing needs yap's video add-on: the yap-video download that goes with " +
				"this build. Put what's in it next to yap, in %s, and start yap again.",
				conn.video_library_dir(),
			),
			wrap_text,
		)
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

	field_row(ui, 120, "Size", {110, 110, 110, 110})
	for p, i in conn.SHARE_PRESETS {
		if choice_button(ui, fmt.tprintf("share preset %s", p.name), p.label, i == preset) &&
		   i != preset {
			settings.set_setting(&ui.settings.share_preset, p.name)
			settings.settings_save(ui.opts.settings_path, ui.settings)
		}
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

	field_row(ui, 120, "Frame rate", {110, 110})
	for fps in conn.SHARE_FPS_CHOICES {
		if choice_button(
			   ui,
			   fmt.tprintf("share fps %d", fps),
			   fmt.tprintf("%d fps", fps),
			   fps == cfg.fps,
		   ) &&
		   fps != cfg.fps {
			ui.settings.share_fps = fps
			settings.settings_save(ui.opts.settings_path, ui.settings)
		}
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

	mu.layout_row(ctx, {120, -1})
	mu.label(ctx, "Encoder")
	if choice_button(ui, "share encoder best", "The best that works", cfg.encoder == "") &&
	   cfg.encoder != "" {
		settings.set_setting(&ui.settings.share_encoder, "")
		settings.settings_save(ui.opts.settings_path, ui.settings)
	}
	encoders := conn.video_encoders()
	if encoders == nil {
		mu.layout_row(ctx, {120, -1})
		mu.label(ctx, "")
		with_text_color(ctx, theme.dim, "Still trying the encoders...", wrap_text)
		ui_redraw_in(ui, ANIMATION_FRAME * 15)
	}
	for e in encoders {
		if !e.works && e.name != cfg.encoder {
			continue
		}
		mu.layout_row(ctx, {120, -1})
		mu.label(ctx, "")
		label := e.label if e.works else fmt.tprintf("%s (doesn't work here)", e.label)
		if choice_button(
			   ui,
			   fmt.tprintf("share encoder %s", e.name),
			   label,
			   e.name == cfg.encoder,
		   ) &&
		   e.name != cfg.encoder {
			settings.set_setting(&ui.settings.share_encoder, e.name)
			settings.settings_save(ui.opts.settings_path, ui.settings)
		}
	}
	if cfg.encoder != "" && encoders != nil {
		// The best encoder that works keeps to what everyone in the room can
		// decode (conn/video.odin). A chosen encoder is used regardless.
		mu.layout_row(ctx, {120, -1})
		mu.label(ctx, "")
		with_text_color(ctx, theme.dim, "Viewers that can't decode it see nothing", wrap_text)
	}

	mu.layout_row(ctx, {-1})
	if .CHANGE in mu.checkbox(ctx, "Show the pointer", &ui.settings.share_cursor) {
		settings.settings_save(ui.opts.settings_path, ui.settings)
	}
}
