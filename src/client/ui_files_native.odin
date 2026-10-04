#+build !wasi
package client

import log "common:wlog"
import "core:c"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "client:conn"
import "client:dialogs"
import "client:platform"
import glfw "client:wglfw"
import "common:proto"

/*
Picking a file to send, on a desktop: the system's file dialog
(dialogs/). It blocks until it's closed, so it runs on a thread of its
own and the window keeps drawing meanwhile; on macOS it has to be the
main thread, so there the frame waits for it instead, as for any modal
dialog there.
*/

File_Pick_Job :: struct {
	thread: ^thread.Thread,
	done:   bool, // atomic: set by the thread, read by the UI
	to:     proto.Account_Id,
	path:   string,
	status: dialogs.Status,
	err:    string,
	// Files to attach (ui_attachments.odin) rather than one to offer:
	// as many as are picked, of any kind, for `at`.
	attach: bool,
	at:     Attach_Target,
	paths:  []string,
}

// The dialog's type list, all of it in one: what may be sent.
@(private = "file")
file_filters :: proc() -> []dialogs.Filter {
	@(static) patterns: cstring
	@(static) filters: [1]dialogs.Filter
	if patterns == nil {
		b := strings.builder_make()
		for ext, i in proto.FILE_EXTENSIONS {
			if i > 0 {
				strings.write_byte(&b, ';')
			}
			strings.write_string(&b, "*.")
			strings.write_string(&b, ext)
		}
		patterns = strings.to_cstring(&b)
		filters[0] = {"Archives, pictures and videos", patterns}
	}
	return filters[:]
}

// file_pick_start opens the file dialog, for a file to offer `to`.
file_pick_start :: proc(ui: ^UI, to: proto.Account_Id) {
	pick_start(ui, {to = to})
}

// attach_pick_start opens the file dialog, for files to attach.
attach_pick_start :: proc(ui: ^UI, at: Attach_Target) {
	pick_start(ui, {attach = true, at = at})
}

@(private = "file")
pick_start :: proc(ui: ^UI, what: File_Pick_Job) {
	if ui.file_pick != nil {
		return // one's open already
	}
	job := new(File_Pick_Job)
	job^ = what
	when ODIN_OS == .Darwin {
		pick_work(job)
		ui.file_pick = job
		file_pick_poll(ui)
	} else {
		job.thread = thread.create_and_start_with_poly_data(job, pick_work, init_context = context)
		if job.thread == nil {
			log.error("could not start the file dialog's thread")
			free(job)
			return
		}
		ui.file_pick = job
	}
}

@(private = "file")
pick_work :: proc(job: ^File_Pick_Job) {
	if job.attach {
		job.paths, job.status, job.err = dialogs.open_files("Attach files", nil)
	} else {
		job.path, job.status, job.err = dialogs.open_file("Send a file", file_filters())
	}
	sync.atomic_store(&job.done, true)
	// The UI may be waiting for input; let it pick the result up now.
	ui_wake()
}

// file_pick_poll finishes a pick once the dialog is closed. Called on the
// UI thread, outside the View lock.
file_pick_poll :: proc(ui: ^UI) {
	job := ui.file_pick
	if job == nil || !sync.atomic_load(&job.done) {
		return
	}
	if job.thread != nil {
		thread.join(job.thread)
		thread.destroy(job.thread)
	}
	ui.file_pick = nil
	defer pick_free(job)
	switch job.status {
	case .Ok:
		if job.attach {
			attach_picked(ui, job)
		} else if ui.session != nil && job.path != "" {
			conn.push_command(
				&ui.session.client.commands,
				conn.Send_File_Command{to = job.to, path = job.path},
			)
			job.path = "" // the command has it now
		}
	case .Cancelled:
	case .Unavailable, .Failed, .Invalid_Argument:
		log.warnf("the file dialog didn't open: %s", job.err)
		when ODIN_OS == .Linux || ODIN_OS == .OpenBSD {
			ui.buddies.notice = "no file dialog to open (install zenity or kdialog)"
		} else {
			ui.buddies.notice = "the file dialog didn't open"
		}
		ui.buddies.notice_at = time.tick_now()
	}
}

// file_pick_wait lets an open dialog finish before shutting down.
file_pick_wait :: proc(ui: ^UI) {
	job := ui.file_pick
	if job == nil {
		return
	}
	if job.thread != nil {
		thread.join(job.thread)
		thread.destroy(job.thread)
	}
	pick_free(job)
	ui.file_pick = nil
}

@(private = "file")
pick_free :: proc(job: ^File_Pick_Job) {
	delete(job.path)
	delete(job.err)
	for p in job.paths {
		delete(p)
	}
	delete(job.paths)
	free(job)
}

// attach_picked takes what was picked to attach.
@(private = "file")
attach_picked :: proc(ui: ^UI, job: ^File_Pick_Job) {
	attach_paths(ui, job.at, job.paths)
}

// drop_callback is files dropped on the window: they're attached after
// the frame, to the composer they were dropped by (attach_dropped).
drop_callback :: proc "c" (window: glfw.WindowHandle, count: c.int, paths: [^]cstring) {
	context = platform.callback_context()
	for i in 0 ..< int(count) {
		append(&g_ui.dropped, strings.clone_from_cstring(paths[i]))
	}
	ui_redraw(g_ui)
}

// attach_dropped attaches what was dropped on the window.
attach_dropped :: proc(ui: ^UI) {
	if ui.session != nil && ui.page != .Settings {
		attach_paths(ui, drop_target(ui), ui.dropped[:])
	}
	for path in ui.dropped {
		delete(path)
	}
	clear(&ui.dropped)
}

// attach_paths attaches files by their paths: each one's name and size,
// as they are now; folders and what isn't there are left out.
@(private = "file")
attach_paths :: proc(ui: ^UI, at: Attach_Target, paths: []string) {
	picked := make([dynamic]Picked_File, context.temp_allocator)
	for path in paths {
		info, err := os.stat(path, context.temp_allocator)
		if err != nil || info.type != .Regular {
			log.warnf("can't attach %s: %v", path, err)
			continue
		}
		append(
			&picked,
			Picked_File{path = path, name = os.base(path), size = u64(max(info.size, 0))},
		)
	}
	attach_add(ui, at, picked[:])
}
