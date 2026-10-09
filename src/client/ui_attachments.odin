package client

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import mu "vendor:microui"

import "client:conn"
import "client:platform"
import "client:render"
import "common:proto"

/*
Attachments in the composers (src/client/conn/attachments.odin has the
rest): the paperclip next to a composer opens the file dialog, for as
many files as are picked (ui_files_*.odin), and they wait above the text
box as chips until the message is sent. A chip clicked is taken off. A
picture pasted into a composer (ui_paste*.odin) joins them the same way.
The pointer on a picture's chip shows the picture above it
(chip_preview_popup). Sending (composer_send) takes them along, even with no text.

Each composer keeps its own: the channel's, the DM page's and each
thread window's.
*/

// Picked_File is a file waiting to go with a composer's next message.
Picked_File :: struct {
	path:           string, // owned; a desktop's
	web_file:       i32, // a browser's (files_io_web.odin)
	data:           []u8, // owned; a pasted picture's
	name:           string, // owned
	size:           u64,
	// Its chip's preview, for a picture (chip_preview_bytes): the bytes
	// read so far (owned; a pasted picture's are `data`), how many, its
	// texture's key (0 until it's first shown), and whether it couldn't
	// be read.
	preview:        []u8,
	preview_read:   int,
	preview_key:    u64,
	preview_failed: bool,
}

picked_files_clear :: proc(files: ^[dynamic]Picked_File) {
	for f in files {
		delete(f.path)
		delete(f.data)
		delete(f.name)
		delete(f.preview)
	}
	clear(files)
}

picked_files_destroy :: proc(files: ^[dynamic]Picked_File) {
	picked_files_clear(files)
	delete(files^)
	files^ = nil
}

// Where the paperclip was pressed, for the files the dialog gives: the
// page's composer (0) or a thread window's, on the page it was.
Attach_Target :: struct {
	page:   Page,
	thread: int,
}

// composer_files_of is where an Attach_Target's files go.
composer_files_of :: proc(ui: ^UI, at: Attach_Target) -> ^[dynamic]Picked_File {
	if at.thread != 0 {
		t := &ui.threads[at.thread - 1]
		return &t.files if t.key != {} else nil
	}
	return &ui.buddies.files if at.page == .Buddies else &ui.chat.files
}

// attach_add takes in what the dialog gave: each file that may go,
// and a notice for those that may not. A file's `data` and `web_file`
// are taken over (and let go of if it may not go); its path and name
// are copied. Call without the View locked.
attach_add :: proc(ui: ^UI, at: Attach_Target, picked: []Picked_File) {
	files := composer_files_of(ui, at)
	max_size: u64
	{
		sync.guard(&ui.view.mutex)
		max_size = ui.view.max_attachment
	}
	refused := ""
	for f in picked {
		switch {
		case files == nil:
		case max_size == 0:
			refused = "This server doesn't take files."
		case len(files) >= proto.MAX_ATTACHMENTS:
			refused = "A message can carry at most 10 files."
		case f.size == 0:
			refused = fmt.tprintf("%s is empty, so it can't be sent.", f.name)
		case f.size > max_size:
			refused = fmt.tprintf(
				"%s is bigger than this server takes (%s).",
				f.name,
				conn.format_bytes(max_size),
			)
		case:
			append(
				files,
				Picked_File {
					path = strings.clone(f.path),
					web_file = f.web_file,
					data = f.data,
					name = strings.clone(f.name),
					size = f.size,
				},
			)
			continue
		}
		if f.web_file != 0 {
			conn.web_file_close(f.web_file)
		}
		delete(f.data)
	}
	if refused != "" {
		conn.view_notice(ui.view, false, refused)
	}
}

// pasted_image_name names a pasted picture after when it was pasted, in
// the local zone: pasted-image-20261008-143012.jpg. In the temp allocator.
pasted_image_name :: proc(ui: ^UI) -> string {
	utc, _ := time.time_to_datetime(time.now())
	dt := chat_local_time(ui, utc)
	return fmt.tprintf(
		"pasted-image-%04d%02d%02d-%02d%02d%02d.jpg",
		dt.year,
		dt.month,
		dt.day,
		dt.hour,
		dt.minute,
		dt.second,
	)
}

// files_said is what a message of only files (a pasted picture, say)
// says in a line about it: a reply's, a link's, a pin's.
files_said :: proc(files: []conn.Msg_File) -> string {
	if len(files) == 1 {
		return fmt.tprintf("the file %s", files[0].name)
	}
	return fmt.tprintf("%d files", len(files))
}

// drop_target is where files dropped on the window go: the thread
// window they're dropped on (the topmost there), or the thread a narrow
// window shows, else the page's composer.
drop_target :: proc(ui: ^UI) -> Attach_Target {
	if ui.narrow {
		if slot := narrow_thread(ui); slot != 0 && ui.page == .Main {
			return {ui.page, slot}
		}
		return {ui.page, 0}
	}
	at := Attach_Target{ui.page, 0}
	top: i32 = -1
	pos := ui.ctx.mouse_pos
	for t, i in ui.threads {
		if t.key != {} && mu.rect_overlaps_vec2(t.rect, pos) && t.zindex > top {
			at.thread, top = i + 1, t.zindex
		}
	}
	return at
}

// attach_button is the paperclip: after the frame, the dialog opens for
// this composer. Not there if the server takes no files, or while a
// message is being edited.
attach_button :: proc(ui: ^UI, c: Composer) {
	ctx := &ui.ctx

	if .Attach_Files not_in ui.view.permissions {
		mu.layout_next(ctx) // its place stays empty
		return
	}

	if ui.view.max_attachment == 0 || c.editing^ != 0 || c.files == nil {
		mu.layout_next(ctx) // its place stays empty
		return
	}
	if .SUBMIT in icon_button(ui, fmt.tprintf("attach %d", c.thread), .Attach, "Attach files") {
		ui.attach_pick = true
		ui.attach_to = {ui.page, c.thread}
	}
}

// What a chip takes besides its name: the ×, the size and the gaps.
@(private = "file")
chip_label :: proc(ctx: ^mu.Context, f: Picked_File, name_width: i32) -> string {
	return fmt.tprintf(
		"× %s  %s",
		cut_to_width(ctx, f.name, name_width),
		conn.format_bytes(f.size),
	)
}

// chip_rows lays a composer's chips out in rows `width` wide: each
// row's widths, in the temp allocator.
@(private = "file")
chip_rows :: proc(ui: ^UI, files: []Picked_File, width: i32) -> [][dynamic]i32 {
	ctx := &ui.ctx
	rows := make([dynamic][dynamic]i32, context.temp_allocator)
	used := width
	gap := ctx.style.spacing
	pad := 2 * ctx.style.padding
	for f in files {
		w := min(ctx.text_width(ctx.style.font, chip_label(ctx, f, width / 2)) + pad, width)
		if len(rows) == 0 || used + gap + w > width {
			append(&rows, make([dynamic]i32, context.temp_allocator))
			used = -gap
		}
		append(&rows[len(rows) - 1], w)
		used += gap + w
	}
	return rows[:]
}

// composer_files_height is how much room a composer's chips take above
// it, spacing included; 0 with none. `width` is the panel's.
composer_files_height :: proc(ui: ^UI, c: Composer, width: i32) -> i32 {
	if c.files == nil || len(c.files) == 0 {
		return 0
	}
	ctx := &ui.ctx
	rows := chip_rows(ui, c.files[:], width)
	return i32(len(rows)) * (control_height(ctx) + ctx.style.spacing)
}

// composer_files draws a composer's chips, in rows; one clicked is taken
// off.
composer_files :: proc(ui: ^UI, c: Composer, width: i32) {
	if c.files == nil || len(c.files) == 0 {
		return
	}
	ctx := &ui.ctx
	rows := chip_rows(ui, c.files[:], width)
	remove := -1
	i := 0
	for row in rows {
		mu.layout_row(ctx, row[:], control_height(ctx))
		for _ in row {
			f := &c.files[i]
			label := chip_label(ctx, f^, width / 2)
			id_name := fmt.tprintf("chip %d %d", c.thread, i)
			if .SUBMIT in
			   stable_button_hint(ui, id_name, label, fmt.tprintf("Take %s off", f.name)) {
				remove = i
			}
			if ctx.hover_id == mu.get_id(ctx, id_name) {
				chip_hovered(ui, f)
			}
			i += 1
		}
	}
	if remove >= 0 {
		ui.chip_preview = {}
		f := c.files[remove]
		delete(f.path)
		delete(f.data)
		delete(f.name)
		delete(f.preview)
		if f.web_file != 0 {
			conn.web_file_close(f.web_file)
		}
		ordered_remove(c.files, remove)
	}
}

/*
A picture's chip with the pointer on it shows the picture over it, with
its hint under it, in a frameless window of its own raised above the
rest, as icon_hint does. The bytes are read the first time (a file
picked on a desktop at once, a browser's as the page has them); the
popup is drawn at the end of the frame from the decoded texture alone,
so a chip taken off or sent meanwhile leaves nothing behind it to use.
*/

// The keys chips' previews are decoded under, beside messages' pictures
// (their blob's id), avatars (AVATAR_KEY) and the emoji sheet: this bit
// and a count.
@(private = "file")
CHIP_PREVIEW_KEY :: u64(1) << 60
@(private = "file")
g_chip_previews: u64

@(private = "file")
CHIP_PREVIEW_WINDOW :: "chip preview"
// The most room the picture takes in the popup.
@(private = "file")
CHIP_PREVIEW_W :: 320
@(private = "file")
CHIP_PREVIEW_H :: 240

// The chip the pointer is on this frame, for chip_preview_popup.
Chip_Preview :: struct {
	key:     u64, // 0 for none
	of:      mu.Rect, // the chip
	caption: string,
}

// chip_preview_bytes is a picture chip's bytes, once they're all read
// (picked_file_read). Not ready while they're on their way (another
// frame is asked for), or if they can't be read (preview_failed).
@(private = "file")
chip_preview_bytes :: proc(ui: ^UI, f: ^Picked_File) -> (data: []u8, ready: bool) {
	if f.data != nil {
		return f.data, true
	}
	if f.preview_failed {
		return nil, false
	}
	if !picked_file_read(f) {
		if !f.preview_failed {
			ui_redraw(ui)
		}
		return nil, false
	}
	return f.preview, true
}

// chip_hovered has a picture's chip show the picture, in place of its
// hint, this frame. Call after the chip, which set the hint.
@(private = "file")
chip_hovered :: proc(ui: ^UI, f: ^Picked_File) {
	if !conn.preview_wanted(f.name, f.size) {
		return
	}
	data, ready := chip_preview_bytes(ui, f)
	if !ready && f.preview_failed {
		return // the plain hint
	}
	if f.preview_key == 0 {
		g_chip_previews += 1
		f.preview_key = CHIP_PREVIEW_KEY | g_chip_previews
	}
	if ready {
		image_want(ui, f.preview_key, data)
	}
	ui.chip_preview = {
		key     = f.preview_key,
		of      = ui.hint_of,
		caption = ui.hint,
	}
	ui.hint = ""
}

// chip_preview_popup draws the picture of the chip under the pointer
// above it (below it if there's no room), with the chip's hint.
chip_preview_popup :: proc(ui: ^UI, window_w, window_h: i32) {
	p := ui.chip_preview
	if p.key == 0 {
		return
	}
	ui.chip_preview = {}
	ctx := &ui.ctx
	pad := ctx.style.padding
	line_h := ctx.text_height(ctx.style.font)
	// While it's being read or decoded, room for "loading picture...".
	pic_w, pic_h := i32(CHIP_PREVIEW_W), i32(CHIP_PREVIEW_H / 2)
	if iw, ih, ok := image_size(ui, p.key); ok {
		fw, fh := conn.fit_box(iw, ih, CHIP_PREVIEW_W, CHIP_PREVIEW_H)
		pic_w, pic_h = i32(fw), i32(fh)
	}
	w := max(pic_w, ctx.text_width(ctx.style.font, p.caption)) + 2 * pad
	h := pic_h + line_h + 3 * pad
	x := min(p.of.x, max(window_w - w, 0))
	y := p.of.y - h - 2
	if y < 0 {
		y = min(p.of.y + p.of.h + 2, max(window_h - h, 0))
	}
	r := mu.Rect{x, y, w, h}
	// Off the chip, so the pointer stays on it.
	cnt := mu.get_container(ctx, CHIP_PREVIEW_WINDOW)
	if cnt == nil {
		return
	}
	cnt.rect = r
	if cnt.zindex != ctx.last_zindex {
		mu.bring_to_front(ctx, cnt)
	}
	if !mu.begin_window(
		ctx,
		CHIP_PREVIEW_WINDOW,
		r,
		{.NO_TITLE, .NO_FRAME, .NO_RESIZE, .NO_SCROLL, .NO_CLOSE, .NO_INTERACT},
	) {
		return
	}
	defer mu.end_window(ctx)
	mu.draw_rect(ctx, r, ctx.style.colors[.BASE])
	mu.draw_box(ctx, r, ctx.style.colors[.BORDER])
	image_fitted(ui, p.key, .Wanted, nil, {x + pad, y + pad, pic_w, pic_h})
	mu.draw_text(
		ctx,
		ctx.style.font,
		p.caption,
		{x + pad, y + 2 * pad + pic_h},
		ctx.style.colors[.TEXT],
	)
}

// composer_send_files sends what's in a composer with its files; true if
// there were files to send.
composer_send_files :: proc(ui: ^UI, c: Composer, text: string, dm_to: proto.Account_Id) -> bool {
	if c.files == nil || len(c.files) == 0 || c.editing^ != 0 {
		return false
	}
	files := make([]conn.Attach_File, len(c.files))
	for f, i in c.files {
		files[i] = {
			path     = strings.clone(f.path),
			web_file = f.web_file,
			web_name = strings.clone(f.name),
			web_size = f.size,
			data     = f.data,
		}
	}
	// The command has the browser's files and the pasted pictures now;
	// they aren't let go of here.
	for &f in c.files {
		f.web_file, f.data = 0, nil
	}
	picked_files_clear(c.files)
	cmd := conn.Attach_Send_Command {
		text  = strings.clone(text),
		dm_to = dm_to,
		files = files,
	}
	if c.thread != 0 {
		t := &ui.threads[c.thread - 1]
		cmd.thread = t.key
		t.timeline.to_end = true
	} else {
		ui.timeline.to_end = true
	}
	conn.push_command(&ui.session.client.commands, cmd)
	return true
}

/*
A message's files in the timeline: a row for each, under its text, with
an icon, the name (cut to fit), the size or how the save is going, and
what can be done: Save, Cancel while it's being saved (with a bar under
the row), Open folder once it's saved. One retention has removed says
so, and has nothing to do.
*/

// The bar under a file being saved.
@(private = "file")
FILES_BAR :: 6
@(private = "file")
FILES_STATE_W :: 90
@(private = "file")
FILES_BUTTON_W :: 100

@(private = "file")
file_save :: proc(ui: ^UI, f: conn.Msg_File) -> (conn.View_Save, bool) {
	return ui.view.saves[f.blob]
}

@(private = "file")
saving :: proc(s: conn.View_Save) -> bool {
	return s.state == .Asking || s.state == .Receiving
}

// How tall a picture's preview is drawn, under its row.
PREVIEW_HEIGHT :: 160

// A picture a message carries is shown under its row, as large as fits
// PREVIEW_HEIGHT.
@(private = "file")
previewed :: proc(f: conn.Msg_File) -> bool {
	return f.blob != 0 && conn.preview_wanted(f.name, f.size)
}

// message_files_height is how far a message's files move the layout
// down. Call with the View locked.
message_files_height :: proc(ui: ^UI, m: conn.View_Message) -> (h: i32) {
	if .Deleted in m.flags {
		return
	}
	ctx := &ui.ctx
	for f in m.files {
		h += control_height(ctx) + ctx.style.spacing
		if s, ok := file_save(ui, f); ok && saving(s) {
			h += FILES_BAR + ctx.style.spacing
		}
		if previewed(f) {
			h += PREVIEW_HEIGHT + ctx.style.spacing
		}
	}
	return
}

// file_preview draws a picture's preview under its row, asking for it
// the first time it's drawn (and again now and then until it's here).
@(private = "file")
file_preview :: proc(
	ui: ^UI,
	conv: proto.Conv_Id,
	m: conn.View_Message,
	i: int,
	f: conn.Msg_File,
) {
	ctx := &ui.ctx
	mu.layout_row(ctx, {-1}, PREVIEW_HEIGHT)
	area := mu.layout_next(ctx)
	area.x += ICON_SIZE_CELL + ctx.style.spacing
	area.w = min(area.w - ICON_SIZE_CELL - ctx.style.spacing, 480)
	img, here := ui.view.blobs[f.blob]
	if !here || img.state != .Ready {
		asked, was := ui.previews_asked[f.blob]
		if !was || time.tick_since(asked) > 10 * time.Second {
			ui.previews_asked[f.blob] = time.tick_now()
			attach_command(ui, conn.Attach_Preview_Command{conv = conv, msg = m.id, index = i})
		}
	}
	if image_fitted(
		ui,
		u64(f.blob),
		img.state if here else .Wanted,
		img.jpeg if here else nil,
		area,
	) {
		// The viewer's Save: the file itself, under its name.
		attach_command(ui, conn.Attach_Save_Command{conv = conv, msg = m.id, index = i})
	}
}

// message_files draws a message's files, in `conv`. Call with the View
// locked.
message_files :: proc(ui: ^UI, conv: proto.Conv_Id, m: conn.View_Message) {
	if .Deleted in m.flags || len(m.files) == 0 {
		return
	}
	ctx := &ui.ctx
	mu.push_id(ctx, uintptr(m.id))
	defer mu.pop_id(ctx)
	for f, i in m.files {
		mu.push_id(ctx, uintptr(i))
		defer mu.pop_id(ctx)
		// The name takes what's left, and one more: microui's "the rest"
		// is a pixel more than the rest, which would widen the panel.
		mu.layout_row(
			ctx,
			{
				ICON_SIZE_CELL,
				-(FILES_STATE_W + FILES_BUTTON_W + 2 * ctx.style.spacing + 1),
				FILES_STATE_W,
				FILES_BUTTON_W,
			},
			control_height(ctx),
		)
		r := mu.layout_next(ctx)
		mu.draw_icon(
			ctx,
			render.icon_id(file_icon(f.name)),
			r,
			theme.dim if f.blob == 0 else ctx.style.colors[.TEXT],
		)
		name_cell := mu.layout_next(ctx)
		mu.layout_set_next(ctx, name_cell, false)
		name := cut_to_width(ctx, f.name, name_cell.w - 2 * ctx.style.padding)
		with_text_color(
			ctx,
			theme.dim if f.blob == 0 else ctx.style.colors[.TEXT],
			name,
			label_proc,
		)

		s, has_save := file_save(ui, f)
		state, color := conn.format_bytes(f.size), theme.dim
		switch {
		case f.blob == 0:
			state = "removed"
		case has_save && saving(s):
			state = fmt.tprintf("%d%%", int(f64(s.done) * 100 / f64(max(s.size, 1))))
		case has_save && s.state == .Done:
			state, color = "saved", theme.speaking
		case has_save && s.state == .Failed:
			state, color = "not saved", theme.error
		}
		with_text_color(ctx, color, state, label_proc)

		save := conn.Attach_Save_Command {
			conv  = conv,
			msg   = m.id,
			index = i,
		}
		switch {
		case f.blob == 0:
			mu.layout_next(ctx)
		case has_save && saving(s):
			if .SUBMIT in stable_button(ctx, "cancel save", "Cancel", {.ALIGN_CENTER}) {
				save.cancel = true
				attach_command(ui, save)
			}
		case has_save && s.state == .Done && !platform.WEB:
			if .SUBMIT in
			   stable_button_hint(ui, "open folder", "Open folder", s.path, {.ALIGN_CENTER}) {
				platform.open_url(os_dir(s.path))
			}
		case:
			if .SUBMIT in
			   stable_button_hint(
				   ui,
				   "save",
				   "Save",
				   fmt.tprintf("Save %s to the downloads folder", f.name),
				   {.ALIGN_CENTER},
			   ) {
				attach_command(ui, save)
			}
		}
		if has_save && saving(s) {
			mu.layout_row(ctx, {-1}, FILES_BAR)
			bar := mu.layout_next(ctx)
			bar.x += ICON_SIZE_CELL + ctx.style.spacing
			bar.w = min(bar.w - ICON_SIZE_CELL - ctx.style.spacing, 300)
			mu.draw_rect(ctx, bar, theme.track)
			done := f32(s.done) / f32(max(s.size, 1))
			mu.draw_rect(
				ctx,
				{bar.x, bar.y, i32(f32(bar.w) * clamp(done, 0, 1)), bar.h},
				theme.speaking,
			)
		}
		if previewed(f) {
			file_preview(ui, conv, m, i, f)
		}
	}
}

// What kind of file a name says it is, by its extension.
File_Kind :: enum {
	Other,
	Archive,
	Picture,
	Video,
	Audio,
	Text,
}

@(rodata, private = "file")
FILE_KIND_EXTENSIONS := [File_Kind][]string {
	.Other   = {},
	.Archive = {
		"zip",
		"rar",
		"7z",
		"tar",
		"gz",
		"tgz",
		"bz2",
		"tbz2",
		"xz",
		"txz",
		"zst",
		"lz",
		"lzma",
		"cab",
		"iso",
		"dmg",
		"deb",
		"rpm",
		"apk",
		"jar",
	},
	.Picture = {
		"png",
		"jpg",
		"jpeg",
		"gif",
		"webp",
		"bmp",
		"tif",
		"tiff",
		"heic",
		"heif",
		"avif",
		"ico",
		"psd",
		"raw",
		"svg",
	},
	.Video   = {
		"mp4",
		"m4v",
		"mkv",
		"webm",
		"mov",
		"avi",
		"wmv",
		"flv",
		"mpg",
		"mpeg",
		"ts",
		"m2ts",
		"3gp",
		"ogv",
	},
	.Audio   = {"mp3", "m4a", "flac", "wav", "ogg", "opus", "aac", "wma", "alac", "mid", "midi"},
	.Text    = {
		"txt",
		"md",
		"pdf",
		"doc",
		"docx",
		"odt",
		"rtf",
		"xls",
		"xlsx",
		"ods",
		"csv",
		"ppt",
		"pptx",
		"odp",
		"epub",
		"log",
		"json",
		"xml",
		"html",
		"htm",
	},
}

file_kind :: proc(name: string) -> File_Kind {
	dot := strings.last_index_byte(name, '.')
	if dot < 0 || dot == len(name) - 1 {
		return .Other
	}
	ext := name[dot + 1:]
	for kind in File_Kind {
		for known in FILE_KIND_EXTENSIONS[kind] {
			if strings.equal_fold(ext, known) {
				return kind
			}
		}
	}
	return .Other
}

// file_icon is the icon beside a file of that name.
@(private = "file")
file_icon :: proc(name: string) -> render.Icon {
	switch file_kind(name) {
	case .Archive:
		return .Archive
	case .Picture:
		return .Picture
	case .Video:
		return .Video
	case .Audio:
		return .App_Audio
	case .Text:
		return .Text_File
	case .Other:
	}
	return .File
}

// The icon's cell at the start of a file's row.
ICON_SIZE_CELL :: 20

// os_dir is the folder a path is in, as far as a path's text says.
@(private = "file")
os_dir :: proc(path: string) -> string {
	i := strings.last_index_any(path, "/\\")
	return path[:i] if i > 0 else path
}

// pending_files draws the files of a message of ours on its way, with
// how far each has got, and one Cancel for the message while its files
// are going up.
pending_files :: proc(ui: ^UI, p: conn.View_Pending) {
	if len(p.files) == 0 {
		return
	}
	ctx := &ui.ctx
	mu.push_id(ctx, uintptr(p.nonce))
	defer mu.pop_id(ctx)
	for f in p.files {
		mu.layout_row(
			ctx,
			{ICON_SIZE_CELL, -(FILES_STATE_W + ctx.style.spacing + 1), FILES_STATE_W},
			control_height(ctx),
		)
		mu.draw_icon(ctx, render.icon_id(file_icon(f.name)), mu.layout_next(ctx), theme.dim)
		name_cell := mu.layout_next(ctx)
		mu.layout_set_next(ctx, name_cell, false)
		with_text_color(
			ctx,
			theme.dim,
			cut_to_width(ctx, f.name, name_cell.w - 2 * ctx.style.padding),
			label_proc,
		)
		with_text_color(
			ctx,
			theme.dim,
			fmt.tprintf(
				"%s, %d%%",
				conn.format_bytes(f.size),
				int(f64(f.done) * 100 / f64(max(f.size, 1))),
			),
			label_proc,
		)
		mu.layout_row(ctx, {-1}, FILES_BAR)
		bar := mu.layout_next(ctx)
		bar.x += ICON_SIZE_CELL + ctx.style.spacing
		bar.w = min(bar.w - ICON_SIZE_CELL - ctx.style.spacing, 300)
		mu.draw_rect(ctx, bar, theme.track)
		done := f32(f.done) / f32(max(f.size, 1))
		mu.draw_rect(
			ctx,
			{bar.x, bar.y, i32(f32(bar.w) * clamp(done, 0, 1)), bar.h},
			theme.speaking,
		)
	}
	if p.uploading {
		mu.layout_row(ctx, {FILES_BUTTON_W})
		if .SUBMIT in stable_button(ctx, "cancel upload", "Cancel", {.ALIGN_CENTER}) {
			attach_command(ui, conn.Attach_Cancel_Command{nonce = p.nonce})
		}
	}
}

@(private = "file")
attach_command :: proc(ui: ^UI, cmd: conn.Command) {
	if ui.session != nil {
		conn.push_command(&ui.session.client.commands, cmd)
	}
}

// control_height is how tall a control is with the row's height left
// to microui: its size and padding.
control_height :: proc(ctx: ^mu.Context) -> i32 {
	return ctx.style.size.y + 2 * ctx.style.padding
}
