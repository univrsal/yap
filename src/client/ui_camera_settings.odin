package client

import "core:fmt"
import "core:time"
import mu "vendor:microui"

import "client:conn"
import "client:platform"
import "client:settings"

// The settings' Camera category: which camera, the quality it is sent at,
// whether our own view is mirrored, and a preview while the category is shown.
//
// The preview is our camera when it is on. Otherwise the camera is opened for
// it but not sent (conn.video_camera_look), and let go of once the category
// isn't shown (camera_after_frame); turning the camera on meanwhile takes it
// over as it is. In a browser that asks for the camera the first time, and
// only then does the browser name its cameras.
//
// A camera that is on goes on with another camera picked here at once
// (camera_switch), and with another quality as the room's tier changes do
// (conn's follow_camera_tier).

@(private = "file")
CAMERA_QUALITY_LABELS := [conn.Camera_Quality]string {
	.Auto = "Auto",
	.High = "High",
	.Low  = "Low",
}

@(private = "file")
CAMERA_QUALITY_NOTES := [conn.Camera_Quality]string {
	.Auto = "720p in a call and with up to two cameras in a channel, smaller as more come on.",
	.High = "1080p in a call (3.5 Mbit/s); in a channel as Auto.",
	.Low  = "At most 640x360 (0.45 Mbit/s), for a slow connection or computer.",
}

// The widest the preview is drawn.
@(private = "file")
PREVIEW_WIDTH :: 480

camera_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	if !platform.WEB && !conn.video_can_watch() {
		mu.layout_row(ctx, {-1})
		with_text_color(
			ctx,
			theme.dim,
			fmt.tprintf(
				"The camera needs yap's video add-on: the yap-video download that goes with this " +
				"build. Put what's in it next to yap, in %s, and start yap again.",
				conn.video_library_dir(),
			),
			wrap_text,
		)
		return
	}
	conn.video_cameras_refresh()
	if !conn.video_can_camera() {
		mu.layout_row(ctx, {-1})
		with_text_color(
			ctx,
			theme.dim,
			"This browser can't use a camera." when platform.WEB else "No cameras found.",
			wrap_text,
		)
		ui_redraw_in(ui, time.Second)
		return
	}

	camera_choice(ui)

	quality := conn.camera_quality(ui.settings.camera_quality)
	field_row(ui, 120, "Quality", {CHOICE_WIDTH})
	if q, ok := enum_dropdown(ui, "camera quality", CAMERA_QUALITY_LABELS, quality); ok {
		settings.set_setting(&ui.settings.camera_quality, conn.CAMERA_QUALITY_NAMES[q])
		settings.settings_save(ui.opts.settings_path, ui.settings)
	}
	mu.layout_row(ctx, {-1})
	with_text_color(ctx, theme.dim, CAMERA_QUALITY_NOTES[quality], wrap_text)

	mu.layout_row(ctx, {-1})
	if .CHANGE in
	   checkbox(
		   ctx,
		   "Mirror my own view (others see it the right way round)",
		   &ui.settings.camera_mirror,
	   ) {
		settings.settings_save(ui.opts.settings_path, ui.settings)
	}

	camera_preview(ui, quality)
}

// camera_choice is the dropdown of the cameras there are. One picked before
// that isn't there now stays picked, and is listed as such.
@(private = "file")
camera_choice :: proc(ui: ^UI) {
	ctx := &ui.ctx
	devices := conn.video_cameras()
	items := make([dynamic]Dropdown_Item, context.temp_allocator)
	ids := make([dynamic]string, context.temp_allocator)
	append(
		&items,
		Dropdown_Item {
			label = "The browser's choice" when platform.WEB else "The first one there is",
		},
	)
	append(&ids, "")
	current := 0
	unnamed := false
	for d, i in devices {
		// A browser that hasn't been allowed a camera yet gives no ids.
		if d.id == "" {
			unnamed = true
			continue
		}
		append(
			&items,
			Dropdown_Item{label = d.name if d.name != "" else fmt.tprintf("Camera %d", i + 1)},
		)
		append(&ids, d.id)
		if d.id == ui.settings.camera_device {
			current = len(items) - 1
		}
	}
	if ui.settings.camera_device != "" && current == 0 {
		append(&items, Dropdown_Item{label = "The one picked before (not there now)"})
		append(&ids, ui.settings.camera_device)
		current = len(items) - 1
	}
	field_row(ui, 120, "Camera", {-1})
	if i, picked := dropdown(ui, "camera device", items[current].label, items[:], current);
	   picked && ids[i] != ui.settings.camera_device {
		settings.set_setting(&ui.settings.camera_device, ids[i])
		settings.settings_save(ui.opts.settings_path, ui.settings)
		camera_switch(ui)
	}
	if unnamed {
		mu.layout_row(ctx, {-1})
		with_text_color(
			ctx,
			theme.dim,
			"The browser names its cameras once yap may use one.",
			wrap_text,
		)
	}
}

// camera_preview shows our camera, or opens the one picked for it while ours
// is off, with what is wrong with it if anything is.
@(private = "file")
camera_preview :: proc(ui: ^UI, quality: conn.Camera_Quality) {
	ctx := &ui.ctx
	ours := conn.video_camera_state()
	why := ""
	waiting := "Waiting for the picture..."
	switch ours {
	case .Live, .Starting:
		waiting = "Your camera is starting..."
	case .Failed:
		why = conn.video_camera_error()
		if why == "" {
			why = "it isn't allowed, or another program has it"
		}
	case .Off:
		conn.video_camera_look(conn.camera_config(1, false, 0, quality), ui.settings.camera_device)
		ui.camera.looked = true
		state, look_why := conn.video_camera_look_state()
		if state == .Failed {
			why = look_why if look_why != "" else "it isn't allowed, or another program has it"
		}
	}

	mu.layout_row(ctx, {-1})
	mu.label(ctx, "Preview")
	w := min(row_room(ctx), PREVIEW_WIDTH)
	mu.layout_row(ctx, {w}, w * 9 / 16)
	r := mu.layout_next(ctx)
	mu.draw_rect(ctx, r, {24, 24, 24, 255})
	if why != "" {
		mu.layout_row(ctx, {-1})
		with_text_color(
			ctx,
			theme.error,
			fmt.tprintf("The camera didn't start: %s.", why),
			wrap_text,
		)
	} else {
		self_view(ui, r, waiting)
	}
	// The preview moves.
	ui_redraw_in(ui, 33 * time.Millisecond)
}
