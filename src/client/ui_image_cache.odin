package client

import "client:conn"
import "client:platform"
import "client:settings"
import "core:fmt"
import mu "vendor:microui"

/*
The image cache: people's pictures and servers' emoji kept between
sessions (conn/image_cache.odin). The UI owns it, opens it in the folder
the settings say (the system's cache folder if they don't say), and
hands it to each connection; the settings page shows how big it is and
changes how big it may get, where it is, or empties it. In a browser
it's the site's IndexedDB, with no folder to choose.
*/

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

// image_cache_settings is the settings page's section for it.
image_cache_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	if .ACTIVE not_in mu.begin_treenode(ctx, "Image cache") {
		return
	}
	defer mu.end_treenode(ctx)

	bytes, count := conn.image_cache_usage(&ui.image_cache)
	mu.layout_row(ctx, {120, -90, -1})
	mu.label(ctx, "In use")
	mu.label(ctx, fmt.tprintf("%s in %d pictures", format_bytes(bytes), count))
	if .SUBMIT in mu.button(ctx, "Clear") {
		conn.image_cache_clear(&ui.image_cache)
	}

	mu.layout_row(ctx, {120, -1})
	mu.label(ctx, "Maximum size")
	if .CHANGE in mu.slider(ctx, &ui.settings.image_cache_mb, 0, settings.MAX_IMAGE_CACHE_MB, 16, "%.0f MB") {
		// Sliders change every frame while dragged; saved within a second.
		ui.settings_dirty = true
		conn.image_cache_set_max(&ui.image_cache, settings.image_cache_bytes(&ui.settings))
	}

	when platform.WEB {
		mu.layout_row(ctx, {-1})
		with_text_color(
			ctx,
			DIM_COLOR,
			"  People's pictures and servers' emoji, kept in this browser for this site. 0 keeps none.",
			label_proc,
		)
	} else {
		folder_settings(ui)
	}
}

// folder_settings picks where a desktop keeps the cache.
@(private = "file")
folder_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	mu.layout_row(ctx, {120, -90, -1})
	mu.label(ctx, "Folder")
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
		DIM_COLOR,
		fmt.tprintf("  Kept in %s. Empty for the default; pictures already kept elsewhere stay there.", folder),
		label_proc,
	)
	with_text_color(ctx, DIM_COLOR, "  People's pictures and servers' emoji. 0 keeps none.", label_proc)
}

// format_bytes is a size the way a person reads one.
@(private = "file")
format_bytes :: proc(n: int) -> string {
	switch {
	case n >= 1024 * 1024 * 1024:
		return fmt.tprintf("%.1f GB", f64(n) / (1024 * 1024 * 1024))
	case n >= 1024 * 1024:
		return fmt.tprintf("%.1f MB", f64(n) / (1024 * 1024))
	case n >= 1024:
		return fmt.tprintf("%.0f KB", f64(n) / 1024)
	}
	return fmt.tprintf("%d bytes", n)
}
