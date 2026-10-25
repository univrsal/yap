package client

import "client:conn"
import "client:platform"
import "client:settings"
import "core:fmt"
import mu "vendor:microui"

// The image cache: people's pictures and servers' emoji, kept between
// sessions (see conn/image_cache.odin). The UI owns it, opens it in the folder
// given in the settings (the system's cache folder if there is none), and
// hands it to each connection. The settings page shows how big it is and
// lets the user change how big it may get, where it is, or empty it. In a
// browser the cache is the site's IndexedDB, with no folder to choose.

// image_cache_start opens the cache where the settings say.
image_cache_start :: proc(ui: ^UI) {
	ui.image_cache_dir_len = copy(ui.image_cache_dir_buf[:], ui.settings.image_cache_dir)
	image_cache_reopen(ui)
}

@(private = "file")
image_cache_reopen :: proc(ui: ^UI) {
	dir := ui.settings.image_cache_dir
	if dir == "" {
		dir = conn.default_image_cache_dir(context.temp_allocator)
	}
	conn.image_cache_open(&ui.image_cache, dir, settings.image_cache_bytes(&ui.settings))
}

// image_cache_settings is the settings page's section for the cache.
image_cache_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx

	bytes, count := conn.image_cache_usage(&ui.image_cache)
	field_row(ui, 120, "In use", {-90, -1})
	mu.label(ctx, fmt.tprintf("%s in %d pictures", conn.format_bytes(u64(bytes)), count))
	if .SUBMIT in mu.button(ctx, "Clear") {
		conn.image_cache_clear(&ui.image_cache)
	}

	mu.layout_row(ctx, {120, -1})
	mu.label(ctx, "Maximum size")
	if .CHANGE in
	   mu.slider(ctx, &ui.settings.image_cache_mb, 0, settings.MAX_IMAGE_CACHE_MB, 16, "%.0f MB") {
		// Sliders change every frame while dragged. The settings are saved within a second.
		ui.settings_dirty = true
		conn.image_cache_set_max(&ui.image_cache, settings.image_cache_bytes(&ui.settings))
	}

	when platform.WEB {
		mu.layout_row(ctx, {-1})
		with_text_color(
			ctx,
			theme.dim,
			"  People's pictures and servers' emoji, kept in this browser for this site. 0 keeps none.",
			wrap_text,
		)
	} else {
		folder_settings(ui)
	}
}

// folder_settings picks where a desktop keeps the cache.
@(private = "file")
folder_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	field_row(ui, 120, "Folder", {-90, -1})
	submit := .SUBMIT in text_box(ui, ui.image_cache_dir_buf[:], &ui.image_cache_dir_len)
	submit |= .SUBMIT in mu.button(ctx, "Apply")
	if submit {
		dir := string(ui.image_cache_dir_buf[:ui.image_cache_dir_len])
		if dir != ui.settings.image_cache_dir {
			settings.set_setting(&ui.settings.image_cache_dir, dir)
			save_settings(ui)
			image_cache_reopen(ui)
		}
	}

	mu.layout_row(ctx, {-1})
	folder := conn.image_cache_dir(&ui.image_cache)
	if folder == "" {
		folder = "nowhere: the folder couldn't be created"
	}
	with_text_color(
		ctx,
		theme.dim,
		fmt.tprintf(
			"  Kept in %s. Empty for the default; pictures already kept elsewhere stay there.",
			folder,
		),
		wrap_text,
	)
	with_text_color(
		ctx,
		theme.dim,
		"  People's pictures and servers' emoji. 0 keeps none.",
		wrap_text,
	)
}
