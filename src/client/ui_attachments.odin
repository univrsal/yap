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

// Attachments in the composers (src/client/conn/attachments.odin has the
// rest): the paperclip next to a composer opens the file dialog, for as
// many files as are picked (see ui_files_*.odin). The files wait above the text
// box as chips until the message is sent. Clicking a chip removes it. A
// picture pasted into a composer (see ui_paste*.odin) joins them the same way.
// Putting the pointer on a picture's chip shows the picture above it
// (see chip_preview_popup). Sending (see composer_send) takes the files along,
// even with no text.
//
// Each composer keeps its own files: the channel's, the DM page's and each
// thread window's.

// Picked_File is a file that is waiting to go with a composer's next message.
Picked_File :: struct {
	path:           string, // owned; a desktop's
	web_file:       i32, // a browser's (files_io_web.odin)
	data:           []u8, // owned; a pasted picture's
	name:           string, // owned
	size:           u64,
	// The preview of its chip, for a picture (see chip_preview_bytes): the bytes
	// read so far (owned; a pasted picture's bytes are in `data`), how many were
	// read, the key of its texture (kind None until it is first shown), and whether it
	// couldn't be read.
	preview:        []u8,
	preview_read:   int,
	preview_key:    Image_Key,
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

// Where the paperclip was pressed, for the files the dialog returns: the
// page's composer (0) or a thread window's, on the page it was on.
Attach_Target :: struct {
	page:   Page,
	thread: int,
}

// Drag is files being dragged over the window, as far as we are told: a
// browser and Wayland say where they are (see drag_frame), elsewhere only the
// drop is known.
Drag :: struct {
	over:  bool,
	// Where they are, or were dropped, once a drag has said so (`known`).
	pos:   mu.Vec2,
	known: bool,
	// The composers that took files in the last frame, the page's (0) and
	// the thread windows', and where the page's conversation is (see
	// drop_zone), for drop_hint.
	takes: bit_set[0 ..= conn.MAX_THREADS],
	page:  mu.Rect,
}

// attach_allowed says whether we may attach files where an Attach_Target's
// message would go: the Attach_Files permission, and the Attach right in a
// channel (a DM on the Buddies page always has it). Call with the View locked.
attach_allowed :: proc(ui: ^UI, at: Attach_Target) -> bool {
	v := ui.view
	if .Attach_Files not_in v.permissions {
		return false
	}
	conv := v.viewing
	if at.thread != 0 {
		conv = ui.threads[at.thread - 1].key.conv
	} else if at.page == .Buddies {
		return true
	}
	return .Attach in rights_in(v, conv)
}

// composer_files_of returns where an Attach_Target's files go.
composer_files_of :: proc(ui: ^UI, at: Attach_Target) -> ^[dynamic]Picked_File {
	if at.thread != 0 {
		t := &ui.threads[at.thread - 1]
		return &t.files if t.key != {} else nil
	}
	return &ui.buddies.files if at.page == .Buddies else &ui.chat.files
}

// attach_add takes in what the dialog returned: each file that may be sent,
// and a notice for those that may not. A file's `data` and `web_file`
// are taken over (and released if the file may not be sent), while its path
// and name are copied. Call without the View locked.
attach_add :: proc(ui: ^UI, at: Attach_Target, picked: []Picked_File) {
	files := composer_files_of(ui, at)
	max_size: u64
	allowed: bool
	{
		sync.guard(&ui.view.mutex)
		max_size = ui.view.max_attachment
		allowed = attach_allowed(ui, at)
	}
	refused := ""
	for f in picked {
		switch {
		case files == nil:
		case !allowed:
			refused = "You can't attach files here."
		case max_size == 0:
			refused = "This server doesn't accept files."
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

// pasted_image_name names a pasted picture after the time it was pasted, in
// the local time zone, with the extension of the format it was compressed to:
// pasted-image-20261008-143012.webp. Allocated in the temp allocator.
pasted_image_name :: proc(ui: ^UI, ext := "webp") -> string {
	utc, _ := time.time_to_datetime(time.now())
	dt := chat_local_time(ui, utc)
	return fmt.tprintf(
		"pasted-image-%04d%02d%02d-%02d%02d%02d.%s",
		dt.year,
		dt.month,
		dt.day,
		dt.hour,
		dt.minute,
		dt.second,
		ext,
	)
}

// files_said returns a short description of a message that only has files (for
// example a pasted picture), for use in a reply, a link or a pin.
files_said :: proc(files: []conn.Msg_File) -> string {
	if len(files) == 1 {
		return fmt.tprintf("the file %s", files[0].name)
	}
	return fmt.tprintf("%d files", len(files))
}

// drop_target is where files dropped on the window go: the thread
// window they are dropped on (the topmost one there), or the thread that a narrow
// window shows, otherwise the page's composer.
drop_target :: proc(ui: ^UI) -> Attach_Target {
	if ui.narrow {
		if slot := narrow_thread(ui); slot != 0 && ui.page == .Main {
			return {ui.page, slot}
		}
		return {ui.page, 0}
	}
	at := Attach_Target{ui.page, 0}
	top: i32 = -1
	// While files are dragged, the pointer doesn't move as far as the window
	// knows (on Wayland and in a browser).
	pos := ui.drag.pos if ui.drag.known else ui.ctx.mouse_pos
	for t, i in ui.threads {
		if t.key != {} && mu.rect_overlaps_vec2(t.rect, pos) && t.zindex > top {
			at.thread, top = i + 1, t.zindex
		}
	}
	return at
}

// attach_button is the paperclip. After the frame, the dialog opens for
// this composer. It isn't shown if the server takes no files, where we may
// not attach any, or while a message is being edited.
attach_button :: proc(ui: ^UI, c: Composer) {
	ctx := &ui.ctx

	if !attach_allowed(ui, {ui.page, c.thread}) {
		mu.layout_next(ctx) // its place stays empty
		return
	}

	if ui.view.max_attachment == 0 || c.editing^ != 0 || c.files == nil {
		mu.layout_next(ctx) // its place stays empty
		return
	}
	ui.drag.takes += {c.thread}
	if .SUBMIT in icon_button(ui, fmt.tprintf("attach %d", c.thread), .Attach, "Attach files") {
		ui.attach_pick = true
		ui.attach_to = {ui.page, c.thread}
	}
}

// drop_zone records the layout cell just begun as the page's conversation:
// what drop_hint marks when files would go to the page's composer.
drop_zone :: proc(ui: ^UI) {
	ui.drag.page = mu.get_layout(&ui.ctx).body
}

// DROP_WINDOW is the window drop_hint draws in.
@(private = "file")
DROP_WINDOW :: "drop hint"

// drop_hint marks, while files are dragged over the window, the conversation
// they would be attached to if dropped there (see drop_target): the page's
// or a thread window's. Nothing is marked where they can't be attached.
drop_hint :: proc(ui: ^UI) {
	ctx := &ui.ctx
	d := &ui.drag
	defer d.takes = {} // attach_button fills it again in the next frame
	if !d.over || ui.session == nil || ui.page == .Settings {
		return
	}
	at := drop_target(ui)
	if at.thread not_in d.takes {
		return
	}
	// A narrow window shows a thread in the page's place.
	r := d.page
	if at.thread != 0 && !ui.narrow {
		r = ui.threads[at.thread - 1].rect
	}
	if r.w <= 0 || r.h <= 0 {
		return
	}
	cnt := mu.get_container(ctx, DROP_WINDOW)
	if cnt == nil {
		return
	}
	cnt.rect = r
	if cnt.zindex != ctx.last_zindex {
		mu.bring_to_front(ctx, cnt)
	}
	opts := mu.Options{.NO_TITLE, .NO_FRAME, .NO_RESIZE, .NO_SCROLL, .NO_CLOSE, .NO_INTERACT}
	if !mu.begin_window(ctx, DROP_WINDOW, r, opts) {
		return
	}
	defer mu.end_window(ctx)

	// The area tinted and outlined in the links' color.
	accent := theme.link
	mu.draw_rect(ctx, r, {accent.r, accent.g, accent.b, 40})
	edge: i32 = 2
	mu.draw_rect(ctx, {r.x, r.y, r.w, edge}, accent)
	mu.draw_rect(ctx, {r.x, r.y + r.h - edge, r.w, edge}, accent)
	mu.draw_rect(ctx, {r.x, r.y, edge, r.h}, accent)
	mu.draw_rect(ctx, {r.x + r.w - edge, r.y, edge, r.h}, accent)

	// In the middle, a paperclip and what dropping does.
	label := "Drop files to attach"
	font := render.font_with_style(ctx.style.font, .Bold)
	pad := ctx.style.padding
	text_w, text_h := ctx.text_width(font, label), ctx.text_height(font)
	h := max(text_h, ICON_BUTTON) + 2 * pad
	w := ICON_BUTTON + text_w + 3 * pad
	box := mu.Rect{r.x + (r.w - w) / 2, r.y + (r.h - h) / 2, w, h}
	render.draw_rounded(ctx, box, ctx.style.colors[.BASE], render.WINDOW_RADIUS)
	render.draw_rounded_border(ctx, box, accent, render.WINDOW_RADIUS)
	mu.draw_icon(
		ctx,
		render.icon_id(.Attach),
		{box.x + pad, box.y + (h - ICON_BUTTON) / 2, ICON_BUTTON, ICON_BUTTON},
		accent,
	)
	mu.draw_text(
		ctx,
		font,
		label,
		{box.x + 2 * pad + ICON_BUTTON, box.y + (h - text_h) / 2},
		ctx.style.colors[.TEXT],
	)
}

// What a chip takes besides its name: the multiplication sign, the size and the gaps.
@(private = "file")
chip_label :: proc(ctx: ^mu.Context, f: Picked_File, name_width: i32) -> string {
	return fmt.tprintf(
		"× %s  %s",
		cut_to_width(ctx, f.name, name_width),
		conn.format_bytes(f.size),
	)
}

// chip_rows lays a composer's chips out in rows that are `width` wide. It returns
// each row's widths, allocated in the temp allocator.
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
// it, including spacing, or 0 if there are none. `width` is the panel's width.
composer_files_height :: proc(ui: ^UI, c: Composer, width: i32) -> i32 {
	if c.files == nil || len(c.files) == 0 {
		return 0
	}
	ctx := &ui.ctx
	rows := chip_rows(ui, c.files[:], width)
	return i32(len(rows)) * (control_height(ctx) + ctx.style.spacing)
}

// composer_files draws a composer's chips in rows. A chip that is clicked is
// removed.
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
			   stable_button_hint(ui, id_name, label, fmt.tprintf("Remove %s", f.name)) {
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

// When the pointer is on a picture's chip, the picture is shown over it, with
// its hint under it, in a frameless window of its own raised above the
// rest, as icon_hint does. The bytes are read the first time (at once for a file
// picked on a desktop, and as the page has them for a browser's file). The
// popup is drawn at the end of the frame from the decoded texture alone,
// so a chip that is removed or sent meanwhile leaves nothing behind for it to use.

// How many chips' previews there have been, which tells their keys apart
// (Image_Kind.Chip_Preview).
@(private = "file")
g_chip_previews: u64

@(private = "file")
CHIP_PREVIEW_WINDOW :: "chip preview"
// The most room the picture takes in the popup.
@(private = "file")
CHIP_PREVIEW_W :: 320
@(private = "file")
CHIP_PREVIEW_H :: 240

// The chip the pointer is on in this frame, for chip_preview_popup.
Chip_Preview :: struct {
	key:     Image_Key, // kind None for none
	of:      mu.Rect, // the chip
	caption: string,
}

// chip_preview_bytes returns a picture chip's bytes once they have all been
// read (see picked_file_read). It is not ready while they are still being read
// (another frame is requested), or if they can't be read (see preview_failed).
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

// chip_hovered makes a picture's chip show the picture in this frame, in place
// of its hint. Call it after the chip, which set the hint.
@(private = "file")
chip_hovered :: proc(ui: ^UI, f: ^Picked_File) {
	if !conn.preview_wanted(f.name, f.size) {
		return
	}
	data, ready := chip_preview_bytes(ui, f)
	if !ready && f.preview_failed {
		return // the plain hint
	}
	if f.preview_key.kind == .None {
		g_chip_previews += 1
		f.preview_key = {
			kind = .Chip_Preview,
			id   = g_chip_previews,
		}
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
// above it (or below it if there is no room), together with the chip's hint.
chip_preview_popup :: proc(ui: ^UI, window_w, window_h: i32) {
	p := ui.chip_preview
	if p.key.kind == .None {
		return
	}
	ui.chip_preview = {}
	ctx := &ui.ctx
	pad := ctx.style.padding
	line_h := ctx.text_height(ctx.style.font)
	// While it is being read or decoded, leave room for its spinner.
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
	// Keep it off the chip, so the pointer stays on the chip.
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
	render.draw_rounded(ctx, r, ctx.style.colors[.BASE], render.WINDOW_RADIUS)
	render.draw_rounded_border(ctx, r, ctx.style.colors[.BORDER], render.WINDOW_RADIUS)
	image_fitted(ui, p.key, .Wanted, nil, {x + pad, y + pad, pic_w, pic_h}, hovered = true)
	mu.draw_text(
		ctx,
		ctx.style.font,
		p.caption,
		{x + pad, y + 2 * pad + pic_h},
		ctx.style.colors[.TEXT],
	)
}

// composer_send_files sends what is in a composer together with its files.
// It returns true if there were files to send.
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
	// The command has the browser's files and the pasted pictures now,
	// so they are not released here.
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

// A message's files in the timeline: a row for each file, under the text, with
// an icon, the name (cut to fit), the size or the progress of the save, and
// the possible actions: Save, Cancel while it is being saved (with a bar under
// the row), and Open folder once it is saved. A file that retention has
// removed says so and has nothing to do.

// The bar under a file that is being saved.
@(private = "file")
FILES_BAR :: 6
@(private = "file")
FILES_STATE_W :: 90
@(private = "file")
FILES_BUTTON_W :: 100 when platform.WEB else 150

// What a message's file has at the end of its line (message_files).
@(private = "file")
File_Action :: enum {
	None, // it is gone from the server
	Save, // an icon button
	Cancel, // while it is being saved
	Browse, // saved, and not something that may be opened
	Open_Browse, // saved
}

// word_button_w is how wide a button with `label` on it is.
@(private = "file")
word_button_w :: proc(ctx: ^mu.Context, label: string) -> i32 {
	return ctx.text_width(ctx.style.font, label) + 4 * ctx.style.padding
}

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

// A picture that a message carries is shown under its row, as large as
// PREVIEW_HEIGHT allows.
@(private = "file")
previewed :: proc(f: conn.Msg_File) -> bool {
	return f.blob != 0 && conn.preview_wanted(f.name, f.size)
}

// message_files_height is how far a message's files push the layout
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

// file_preview draws a picture's preview under its row. It requests the preview
// the first time it is drawn (and again now and then until it arrives).
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
		Image_Key{kind = .Picture, id = u64(f.blob)},
		img.state if here else .Wanted,
		img.jpeg if here else nil,
		area,
		f.name,
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
		s, has_save := file_save(ui, f)
		action := File_Action.Save
		switch {
		case f.blob == 0:
			action = .None
		case has_save && saving(s):
			action = .Cancel
		case has_save && s.state == .Done && !platform.WEB && !platform.file_openable(s.path):
			// Not something that may be opened (platform.open_file), so it can
			// only be shown in its folder.
			action = .Browse
		case has_save && s.state == .Done && !platform.WEB:
			action = .Open_Browse
		}
		// The button's cell is as wide as what is in it: Save is an icon, so
		// that the name and the size keep the room.
		button_w := icon_button_w(ctx)
		#partial switch action {
		case .Cancel:
			button_w = word_button_w(ctx, "Cancel")
		case .Browse:
			button_w = word_button_w(ctx, "Browse")
		case .Open_Browse:
			button_w =
				word_button_w(ctx, "Open") + ctx.style.spacing + word_button_w(ctx, "Browse")
		}
		// The name takes what is left, and one more: microui's "the rest"
		// is a pixel more than the rest, which would widen the panel.
		mu.layout_row(
			ctx,
			{
				ICON_SIZE_CELL,
				-(FILES_STATE_W + button_w + 2 * ctx.style.spacing + 1),
				FILES_STATE_W,
				button_w,
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
		switch action {
		case .None:
			mu.layout_next(ctx)
		case .Cancel:
			if .SUBMIT in stable_button(ctx, "cancel save", "Cancel", {.ALIGN_CENTER}) {
				save.cancel = true
				attach_command(ui, save)
			}
		case .Browse:
			if .SUBMIT in
			   stable_button_hint(
				   ui,
				   "browse",
				   "Browse",
				   fmt.tprintf("Show %s in its folder", f.name),
				   {.ALIGN_CENTER},
			   ) {
				platform.open_folder(os_dir(s.path))
			}
		case .Open_Browse:
			cell := mu.layout_next(ctx)
			open_w := word_button_w(ctx, "Open")
			mu.layout_set_next(ctx, {cell.x, cell.y, open_w, cell.h}, false)
			if .SUBMIT in
			   stable_button_hint(
				   ui,
				   "open",
				   "Open",
				   fmt.tprintf("Open %s with the default application", f.name),
				   {.ALIGN_CENTER},
			   ) {
				platform.open_file(s.path)
			}
			browse_x := cell.x + open_w + ctx.style.spacing
			mu.layout_set_next(ctx, {browse_x, cell.y, cell.x + cell.w - browse_x, cell.h}, false)
			if .SUBMIT in stable_button_hint(ui, "browse", "Browse", s.path, {.ALIGN_CENTER}) {
				platform.open_folder(os_dir(s.path))
			}
		case .Save:
			hint := fmt.tprintf("Save %s to the downloads folder", f.name)
			if .SUBMIT in icon_button(ui, "save", .Download, hint) {
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

// What kind of file a name says it is, going by its extension.
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

// file_icon is the icon beside a file with that name.
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

// os_dir is the folder that a path is in, as far as the path's text says.
@(private = "file")
os_dir :: proc(path: string) -> string {
	i := strings.last_index_any(path, "/\\")
	return path[:i] if i > 0 else path
}

// pending_files draws the files of one of our messages that is on its way, with
// how far each has got, and one Cancel button for the message while its files
// are being uploaded.
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

// control_height is how tall a control is when the row's height is left
// to microui: its size and padding.
control_height :: proc(ctx: ^mu.Context) -> i32 {
	return ctx.style.size.y + 2 * ctx.style.padding
}
