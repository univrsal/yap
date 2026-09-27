#+build !wasi
package client

import log "../common/wlog"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import glfw "wglfw"

import "../proto"
import "dialogs"

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
	to:     [proto.KEY_SIZE]u8,
	path:   string,
	status: dialogs.Status,
	err:    string,
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
file_pick_start :: proc(ui: ^UI, to: [proto.KEY_SIZE]u8) {
	if ui.file_pick != nil {
		return // one's open already
	}
	job := new(File_Pick_Job)
	job.to = to
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
	job.path, job.status, job.err = dialogs.open_file("Send a file", file_filters())
	sync.atomic_store(&job.done, true)
	// The UI may be waiting for input; let it pick the result up now.
	glfw.PostEmptyEvent()
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
	defer {
		delete(job.path)
		delete(job.err)
		free(job)
	}
	switch job.status {
	case .Ok:
		if ui.session != nil && job.path != "" {
			push_command(
				&ui.session.client.commands,
				Send_File_Command{to = job.to, path = job.path},
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
	delete(job.path)
	delete(job.err)
	free(job)
	ui.file_pick = nil
}
