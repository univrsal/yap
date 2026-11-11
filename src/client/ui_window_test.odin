#+build windows
package client

import "core:log"
import "core:testing"

import "client:render"
import "client:settings"
import glfw "client:wglfw"

// Hiding to the tray closes the window and opening it again makes a new one,
// with a new GPU device (see hide_to_tray), and a restart does the same with
// the place it was in read back from the settings. These open and close a
// real window, kept hidden, a few times over. Where there is no desktop to
// open one on, there is nothing to test and they pass.
//
// They are all one test, because GLFW wants one thread at a time. g_ui is
// left alone (other tests use it): window_close notes the window's place
// itself, without the callbacks that go through g_ui.

// The window comes back where it went away and at the same size, with the
// title bar merged into it or not. Merged, the client area covers the frame,
// which CreateWindow then put around it again: a frame and a title bar bigger,
// and further up and left, every time. A window that was maximized comes back
// maximized, with the place to go back to that it had before.
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
	monitors := glfw.GetMonitors()
	if len(monitors) == 0 {
		log.info("no screen here, so no window to test")
		return
	}
	window_test_off_screen(t)

	// On each screen there is: one with another scale than the main one
	// has a frame of another thickness (see titlebar_client_rect).
	for monitor, screen in monitors {
		mx, my, _, _ := glfw.GetMonitorWorkarea(monitor)
		for merged in ([?]bool{true, false}) {
			for maximized in ([?]bool{false, true}) {
				ui := new(UI)
				defer {
					delete(ui.window_title)
					delete(ui.images.textures)
					delete(ui.images.draws)
					free(ui)
				}
				ui.settings.merge_title_bar = merged
				start := settings.Window_Place {
					x         = mx + 100,
					y         = my + 120,
					w         = 640,
					h         = 480,
					maximized = maximized,
					placed    = true,
				}
				ui.settings.window = start
				_, textures := render.texture_memory()

				for cycle in 0 ..< 3 {
					if !window_test_open(ui) {
						return
					}
					window_test_pictures(ui)
					window_close(ui)
					testing.expectf(
						t,
						ui.settings.window == start,
						"screen %d, merged %v, maximized %v, cycle %d: reopens at %v",
						screen,
						merged,
						maximized,
						cycle,
						ui.settings.window,
					)
					_, left := render.texture_memory()
					testing.expectf(
						t,
						left == textures,
						"screen %d, merged %v, maximized %v, cycle %d: %d textures left behind",
						screen,
						merged,
						maximized,
						cycle,
						left - textures,
					)
				}
			}
		}
	}
}

// A place that is on none of the screens there are now (the screen it was on
// was unplugged) is left to the desktop, which puts the window somewhere it
// can be seen.
@(private = "file")
window_test_off_screen :: proc(t: ^testing.T) {
	ui := new(UI)
	defer {
		delete(ui.window_title)
		free(ui)
	}
	ui.settings.window = {
		x      = -100_000,
		y      = -100_000,
		w      = 640,
		h      = 480,
		placed = true,
	}
	testing.expect(t, !window_on_screen(ui.settings.window))
	if !window_test_open(ui) {
		return
	}
	window_close(ui)
	testing.expectf(
		t,
		window_on_screen(ui.settings.window),
		"left off the screens at %v",
		ui.settings.window,
	)
	testing.expect_value(t, ui.settings.window.w, 640)
	testing.expect_value(t, ui.settings.window.h, 480)
}

// window_test_open opens the window without showing it.
@(private = "file")
window_test_open :: proc(ui: ^UI) -> bool {
	glfw.WindowHint(glfw.VISIBLE, false)
	if !window_open(ui) {
		log.info("no window could be opened here")
		return false
	}
	return true
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
