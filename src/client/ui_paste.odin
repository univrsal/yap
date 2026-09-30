#+build !wasi
package client

import log "common:wlog"
import "core:sync"
import "core:thread"
import mu "vendor:microui"
import glfw "client:wglfw"

import "client:clipboard"
import "client:conn"

/*
Pasting an image runs on a thread of its own: the program that owns the
clipboard may take a moment to hand the data over, and a large image
then takes a while to scale and compress (about a second for a 4K
screenshot). The UI keeps drawing meanwhile.

Only one paste runs at a time. The clipboard is read on this thread
(Wayland events for our data device are queued by GLFW's loop and
handled here; the X11 connection is ours alone), while the window, the
microui state and the View stay with the UI thread.
*/

Paste_Job :: struct {
	thread:             ^thread.Thread,
	done:               bool, // atomic: set by the thread, read by the UI
	err:                clipboard.Error,
	image:              conn.Chat_Image,
	ok:                 bool, // the image was scaled and compressed
	target:             Paste_Target, // where it goes
	source_w, source_h: int, // before scaling, for the log
}

// paste_start reads the clipboard in the background, unless a paste is
// already running.
paste_start :: proc(ui: ^UI) {
	if ui.paste != nil {
		log.debug("ui: the last paste is still being read")
		return
	}
	job := new(Paste_Job)
	job.target = ui.paste_to
	job.thread = thread.create_and_start_with_poly_data(job, paste_work, init_context = context)
	if job.thread == nil {
		log.error("could not start the paste thread")
		free(job)
		return
	}
	ui.paste = job
}

@(private = "file")
paste_work :: proc(job: ^Paste_Job) {
	img, err := clipboard.read_image()
	defer clipboard.image_destroy(&img)
	job.err = err
	if err == .None {
		job.source_w, job.source_h = img.width, img.height
		job.image, job.ok = image_prepare(img)
	}
	sync.atomic_store(&job.done, true)
	// The UI may be waiting for input; let it pick the result up now.
	glfw.PostEmptyEvent()
}

// paste_poll finishes a paste once its thread is done. It's called on
// the UI thread, outside the View lock.
paste_poll :: proc(ui: ^UI) {
	job := ui.paste
	if job == nil || !sync.atomic_load(&job.done) {
		return
	}
	thread.join(job.thread)
	thread.destroy(job.thread)
	ui.paste = nil
	defer {
		conn.chat_image_destroy(&job.image)
		free(job)
	}

	switch job.err {
	case .None:
		if !job.ok {
			log.warn("the pasted image could not be prepared for sending")
			return
		}
		if job.image.width != job.source_w || job.image.height != job.source_h {
			log.infof(
				"pasted a %dx%d image, scaled to %dx%d, %d KB as JPEG",
				job.source_w,
				job.source_h,
				job.image.width,
				job.image.height,
				len(job.image.jpeg) / 1024,
			)
		} else {
			log.infof(
				"pasted a %dx%d image, %d KB as JPEG",
				job.image.width,
				job.image.height,
				len(job.image.jpeg) / 1024,
			)
		}
		// Sending takes the image over, so it isn't freed here.
		send_pasted_image(ui, job.target, job.image)
		job.image = {}
		return
	case .Too_Large:
		log.warnf(
			"the image on the clipboard is too large (at most %d MB of data and %d megapixels)",
			clipboard.MAX_DATA_SIZE / (1024 * 1024),
			clipboard.MAX_PIXELS / 1_000_000,
		)
		return
	case .Decode_Failed:
		log.warn("the image on the clipboard is in a format that can't be read")
		return
	case .Timeout:
		log.warn("the program holding the clipboard didn't hand it over")
	case .No_Image, .Unavailable:
	}
	// No image: the chat box takes the clipboard's text as if it had been
	// typed, on the next frame.
	if text, ok := ui.ctx.textbox_state.get_clipboard(ui.ctx.textbox_state.clipboard_user_data);
	   ok {
		mu.input_text(&ui.ctx, text)
	}
}

// paste_wait lets a running paste finish and throws its result away, so
// nothing is still using the clipboard when it's shut down.
paste_wait :: proc(ui: ^UI) {
	job := ui.paste
	if job == nil {
		return
	}
	thread.join(job.thread)
	thread.destroy(job.thread)
	conn.chat_image_destroy(&job.image)
	free(job)
	ui.paste = nil
}
