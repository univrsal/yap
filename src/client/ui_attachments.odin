package client

import "core:fmt"
import "core:strings"
import "core:sync"
import mu "vendor:microui"

import "common:proto"
import "client:conn"
import "client:platform"
import "client:render"

/*
Attachments in the composers (src/client/conn/attachments.odin has the
rest): the paperclip next to a composer opens the file dialog, for as
many files as are picked (ui_files_*.odin), and they wait above the text
box as chips until the message is sent. A chip clicked is taken off.
Sending (composer_send) takes them along, even with no text.

Each composer keeps its own: the channel's, the DM page's and each
thread window's.
*/

// Picked_File is a file waiting to go with a composer's next message.
Picked_File :: struct {
	path:     string, // owned; a desktop's
	web_file: i32, // a browser's (files_io_web.odin)
	name:     string, // owned
	size:     u64,
}

picked_files_clear :: proc(files: ^[dynamic]Picked_File) {
	for f in files {
		delete(f.path)
		delete(f.name)
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
// and a notice for those that may not. Call without the View locked.
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
		case len(files) >= proto.MAX_ATTACHMENTS:
			refused = "A message can carry at most 10 files."
		case f.size == 0:
			refused = fmt.tprintf("%s is empty, so it can't be sent.", f.name)
		case f.size > max_size:
			refused = fmt.tprintf("%s is bigger than this server takes (%s).", f.name, conn.format_bytes(max_size))
		case:
			append(files, Picked_File{strings.clone(f.path), f.web_file, strings.clone(f.name), f.size})
			continue
		}
		if f.web_file != 0 {
			conn.web_file_close(f.web_file)
		}
	}
	if refused != "" {
		conn.view_notice(&ui.view, false, refused)
	}
}

// attach_button is the paperclip: after the frame, the dialog opens for
// this composer. Not there if the server takes no files, or while a
// message is being edited.
attach_button :: proc(ui: ^UI, c: Composer) {
	ctx := &ui.ctx
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
	return fmt.tprintf("× %s  %s", cut_to_width(ctx, f.name, name_width), conn.format_bytes(f.size))
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
			f := c.files[i]
			label := chip_label(ctx, f, width / 2)
			if .SUBMIT in stable_button_hint(ui, fmt.tprintf("chip %d %d", c.thread, i), label, fmt.tprintf("Take %s off", f.name)) {
				remove = i
			}
			i += 1
		}
	}
	if remove >= 0 {
		f := c.files[remove]
		delete(f.path)
		delete(f.name)
		if f.web_file != 0 {
			conn.web_file_close(f.web_file)
		}
		ordered_remove(c.files, remove)
	}
}

// composer_send_files sends what's in a composer with its files; true if
// there were files to send.
composer_send_files :: proc(ui: ^UI, c: Composer, text: string, dm_to: proto.Account_Id) -> bool {
	if c.files == nil || len(c.files) == 0 || c.editing^ != 0 {
		return false
	}
	files := make([]conn.Attach_File, len(c.files))
	for f, i in c.files {
		files[i] = {path = strings.clone(f.path), web_file = f.web_file, web_name = strings.clone(f.name), web_size = f.size}
	}
	// The command has the browser's files now; they aren't closed here.
	for &f in c.files {
		f.web_file = 0
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
	}
	return
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
		mu.layout_row(ctx, {ICON_SIZE_CELL, -(FILES_STATE_W + FILES_BUTTON_W + 2 * ctx.style.spacing + 1), FILES_STATE_W, FILES_BUTTON_W}, control_height(ctx))
		r := mu.layout_next(ctx)
		mu.draw_icon(ctx, render.icon_id(.File), r, CHAT_DIM_COLOR if f.blob == 0 else ctx.style.colors[.TEXT])
		name_cell := mu.layout_next(ctx)
		mu.layout_set_next(ctx, name_cell, false)
		name := cut_to_width(ctx, f.name, name_cell.w - 2 * ctx.style.padding)
		with_text_color(ctx, CHAT_DIM_COLOR if f.blob == 0 else ctx.style.colors[.TEXT], name, label_proc)

		s, has_save := file_save(ui, f)
		state, color := conn.format_bytes(f.size), CHAT_DIM_COLOR
		switch {
		case f.blob == 0:
			state = "removed"
		case has_save && saving(s):
			state = fmt.tprintf("%d%%", int(f64(s.done) * 100 / f64(max(s.size, 1))))
		case has_save && s.state == .Done:
			state, color = "saved", SPEAKING_COLOR
		case has_save && s.state == .Failed:
			state, color = "not saved", ERROR_COLOR
		}
		with_text_color(ctx, color, state, label_proc)

		save := conn.Attach_Save_Command{conv = conv, msg = m.id, index = i}
		switch {
		case f.blob == 0:
			mu.layout_next(ctx)
		case has_save && saving(s):
			if .SUBMIT in stable_button(ctx, "cancel save", "Cancel", {.ALIGN_CENTER}) {
				save.cancel = true
				attach_command(ui, save)
			}
		case has_save && s.state == .Done && !platform.WEB:
			if .SUBMIT in stable_button_hint(ui, "open folder", "Open folder", s.path, {.ALIGN_CENTER}) {
				platform.open_url(os_dir(s.path))
			}
		case:
			if .SUBMIT in stable_button_hint(ui, "save", "Save", fmt.tprintf("Save %s to the downloads folder", f.name), {.ALIGN_CENTER}) {
				attach_command(ui, save)
			}
		}
		if has_save && saving(s) {
			mu.layout_row(ctx, {-1}, FILES_BAR)
			bar := mu.layout_next(ctx)
			bar.x += ICON_SIZE_CELL + ctx.style.spacing
			bar.w = min(bar.w - ICON_SIZE_CELL - ctx.style.spacing, 300)
			mu.draw_rect(ctx, bar, {60, 60, 60, 255})
			done := f32(s.done) / f32(max(s.size, 1))
			mu.draw_rect(ctx, {bar.x, bar.y, i32(f32(bar.w) * clamp(done, 0, 1)), bar.h}, SPEAKING_COLOR)
		}
	}
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
		mu.layout_row(ctx, {ICON_SIZE_CELL, -(FILES_STATE_W + ctx.style.spacing + 1), FILES_STATE_W}, control_height(ctx))
		mu.draw_icon(ctx, render.icon_id(.File), mu.layout_next(ctx), CHAT_DIM_COLOR)
		name_cell := mu.layout_next(ctx)
		mu.layout_set_next(ctx, name_cell, false)
		with_text_color(ctx, CHAT_DIM_COLOR, cut_to_width(ctx, f.name, name_cell.w - 2 * ctx.style.padding), label_proc)
		with_text_color(ctx, CHAT_DIM_COLOR, fmt.tprintf("%s, %d%%", conn.format_bytes(f.size), int(f64(f.done) * 100 / f64(max(f.size, 1)))), label_proc)
		mu.layout_row(ctx, {-1}, FILES_BAR)
		bar := mu.layout_next(ctx)
		bar.x += ICON_SIZE_CELL + ctx.style.spacing
		bar.w = min(bar.w - ICON_SIZE_CELL - ctx.style.spacing, 300)
		mu.draw_rect(ctx, bar, {60, 60, 60, 255})
		done := f32(f.done) / f32(max(f.size, 1))
		mu.draw_rect(ctx, {bar.x, bar.y, i32(f32(bar.w) * clamp(done, 0, 1)), bar.h}, SPEAKING_COLOR)
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
