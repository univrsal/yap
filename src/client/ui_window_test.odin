#+build windows
package client

import "core:log"
import "core:testing"

import "client:render"
import glfw "client:wglfw"

// Hiding to the tray closes the window and opening it again makes a new one,
// with a new GPU device (see hide_to_tray). These open and close a real
// window, kept hidden, a few times over. Where there is no desktop to open
// one on, there is nothing to test and they pass.
//
// Only this test uses GLFW, which wants one thread at a time.

// The window comes back at the size it went away at, with the title bar
// merged into it or not. Merged, the client area covers the frame, which
// CreateWindow then put around it again: a frame and a title bar bigger
// every time.
//
// What the device holds of the pictures goes with it. A Direct3D texture keeps
// its device alive, so one that was only forgotten kept a whole device, with
// its memory and its driver's threads, per window.
@(test)
test_window_reopen :: proc(t: ^testing.T) {
	if !glfw.Init() {
		log.info("no GLFW here, so no window to test")
		return
	}
	defer glfw.Terminate()

	for merged in ([?]bool{true, false}) {
		ui := new(UI)
		defer free(ui)
		ui.settings.merge_title_bar = merged
		ui.window_size = {640, 480}
		_, textures := render.texture_memory()

		for cycle in 0 ..< 3 {
			glfw.WindowHint(glfw.VISIBLE, false)
			if !window_open(ui) {
				log.info("no window could be opened here")
				delete(ui.window_title)
				return
			}
			window_test_pictures(ui)
			window_close(ui)
			testing.expectf(
				t,
				ui.window_size == {640, 480},
				"merged %v, cycle %d: reopens at %v",
				merged,
				cycle,
				ui.window_size,
			)
			_, left := render.texture_memory()
			testing.expectf(
				t,
				left == textures,
				"merged %v, cycle %d: %d textures left behind",
				merged,
				cycle,
				left - textures,
			)
		}
		delete(ui.window_title)
		delete(ui.images.textures)
		delete(ui.images.draws)
	}
}

// window_test_pictures puts on the window's device what drawing the avatars
// and a message's picture would: the disc and ring that avatars are drawn
// with, and a picture's texture.
@(private = "file")
window_test_pictures :: proc(ui: ^UI) {
	gpu := &ui.renderer.gpu
	pixels := make([]u8, 16 * 16 * 4, context.temp_allocator)
	ui.avatars.disc = render.gpu_texture_make(gpu, .Rgba, 16, 16, pixels)
	ui.avatars.have = true
	ui.avatars.ring = render.gpu_texture_make(gpu, .Rgba, 16, 16, pixels, mipmaps = true)
	ui.avatars.have_ring = true
	ui.images.textures[{kind = .Picture, id = 1}] = {
		state   = .Ready,
		texture = render.gpu_texture_make(gpu, .Rgba, 16, 16, pixels),
	}
}
