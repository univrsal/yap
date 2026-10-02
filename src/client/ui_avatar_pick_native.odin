#+build !wasi
package client

import log "common:wlog"
import "core:sync"
import "core:thread"
import glfw "client:wglfw"

import "client:clipboard"
import "client:conn"
import "client:dialogs"

/*
Choosing our picture on a desktop: from an image file (the system's file
dialog) or the clipboard, read and made into a picture (avatar_prepare)
on a thread of its own, as a paste is (ui_paste.odin); on macOS the
dialog has to be on the main thread, so there the frame waits for it.
*/

Avatar_Pick :: struct {
	thread: ^thread.Thread,
	done:   bool, // atomic: set by the thread, read by the UI
	paste:  bool, // from the clipboard, not a file
	image:  conn.Chat_Image,
	ok:     bool,
	why:    string, // static: what went wrong, for the settings to say
}

@(private = "file")
AVATAR_FILTERS := [1]dialogs.Filter{{"Pictures", "*.png;*.jpg;*.jpeg;*.gif;*.bmp;*.webp"}}

// avatar_pick_start reads a picture from a file or the clipboard.
avatar_pick_start :: proc(ui: ^UI, paste: bool) {
	if ui.profiles.pick != nil {
		return
	}
	job := new(Avatar_Pick)
	job.paste = paste
	ui.profiles.pick_notice = ""
	when ODIN_OS == .Darwin {
		if !paste {
			pick_work(job)
			ui.profiles.pick = job
			avatar_pick_poll(ui)
			return
		}
	}
	job.thread = thread.create_and_start_with_poly_data(job, pick_work, init_context = context)
	if job.thread == nil {
		log.error("could not start the picture's thread")
		free(job)
		return
	}
	ui.profiles.pick = job
}

@(private = "file")
pick_work :: proc(job: ^Avatar_Pick) {
	defer {
		sync.atomic_store(&job.done, true)
		glfw.PostEmptyEvent()
	}
	if job.paste {
		img, err := clipboard.read_image()
		defer clipboard.image_destroy(&img)
		if err != .None {
			job.why = "there's no picture on the clipboard"
			return
		}
		job.image, job.ok = avatar_prepare(img)
	} else {
		path, status, err := dialogs.open_file("Choose a picture", AVATAR_FILTERS[:])
		defer delete(path)
		defer delete(err)
		#partial switch status {
		case .Ok:
		case .Cancelled:
			return
		case:
			job.why = "the file dialog didn't open"
			return
		}
		job.image, job.ok = avatar_load(path)
	}
	if !job.ok && job.why == "" {
		job.why = "that isn't a picture that can be read"
	}
}

// avatar_pick_poll sends the picture once it's ready. Called on the UI
// thread, outside the View lock.
avatar_pick_poll :: proc(ui: ^UI) {
	job := ui.profiles.pick
	if job == nil || !sync.atomic_load(&job.done) {
		return
	}
	if job.thread != nil {
		thread.join(job.thread)
		thread.destroy(job.thread)
	}
	ui.profiles.pick = nil
	defer free(job)
	if !job.ok {
		ui.profiles.pick_notice = job.why
		conn.chat_image_destroy(&job.image)
		return
	}
	if ui.session == nil {
		conn.chat_image_destroy(&job.image)
		return
	}
	conn.push_command(&ui.session.client.commands, conn.Avatar_Command{image = job.image})
}

// avatar_pick_wait lets a pick finish before shutting down.
avatar_pick_wait :: proc(ui: ^UI) {
	job := ui.profiles.pick
	if job == nil {
		return
	}
	if job.thread != nil {
		thread.join(job.thread)
		thread.destroy(job.thread)
	}
	conn.chat_image_destroy(&job.image)
	free(job)
	ui.profiles.pick = nil
}
