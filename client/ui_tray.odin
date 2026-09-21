#+build !wasi
package client

import log "../common/wlog"
import "core:strings"
import "core:sync"
import mu "vendor:microui"
import glfw "wglfw"

import "tray"

/*
The tray icon: a microphone in the system tray showing whether we're
talking, muted or deafened, with a right-click menu to disconnect or
quit. It's drawn from the same shapes as the icons in the window (see
ui_icons.odin), so the two always say the same thing.

It's off by default and turned on in the settings. Nothing depends on
it: a desktop with nowhere to put a tray icon just doesn't get one, and
the client carries on without saying much about it.

With an icon in the tray, closing the window puts the client there
instead of ending it: the voice carries on and the icon is the way back.
Quit in the tray menu is what actually ends it.

traycon hands its clicks back to us from inside tray_step, on this
thread and in the middle of our own frame, so the callbacks only write
down what was asked for and the loop acts on it once the step is over.
*/

// The pixels the desktop is given. 32 is traycon's recommended size.
@(private = "file")
TRAY_ICON_PIXELS :: 32

// The tray sits on somebody's panel, which may be light or dark, so
// these are the colours from the window with the pale ones darkened.
@(private = "file")
TRAY_QUIET :: mu.Color{140, 148, 160, 255}
@(private = "file")
TRAY_TALKING :: mu.Color{60, 190, 90, 255}
@(private = "file")
TRAY_OFF :: mu.Color{225, 80, 80, 255}

@(private = "file")
MENU_WINDOW :: 1
@(private = "file")
MENU_DISCONNECT :: 2
@(private = "file")
MENU_QUIT :: 3

// What a click asked for, acted on after traycon is done stepping.
Tray_Request :: enum {
	None,
	Show_Window,
	Toggle_Window,
	Disconnect,
	Quit,
}

Tray :: struct {
	handle:               ^tray.Tray,
	// What the icon is showing, so it's only redrawn when it changes.
	icon:                 Icon,
	color:                mu.Color,
	// What the menu was last built for: Disconnect is greyed out when
	// there's nothing to disconnect from, and the first item says
	// whether the window is to be shown or hidden.
	connected:            bool,
	hidden:               bool,
	request:              Tray_Request,
	// The desktop wouldn't take an icon, or took ours away again. We
	// stop asking until the setting is switched off and on, and leave
	// the setting alone: it's the user's, and their tray may well be
	// there the next time they start the client.
	refused:              bool,
}

// tray_update keeps the icon in step with the client and handles what
// the menu asked for. Called once a frame.
tray_update :: proc(ui: ^UI) {
	t := &ui.tray
	switch {
	case ui.settings.tray && t.handle == nil && !t.refused:
		tray_show(ui)
	case !ui.settings.tray:
		// The icon is the only way back to a hidden window, so it can't
		// go while the window is away.
		show_from_tray(ui)
		tray_hide(ui)
		t.refused = false // switching it on again is a fresh ask
	}
	if t.handle == nil {
		return
	}

	if icon, color := tray_state(ui); icon != t.icon || color != t.color {
		pixels := icon_rgba(icon, TRAY_ICON_PIXELS, color, context.temp_allocator)
		tray.update_icon(t.handle, raw_data(pixels), TRAY_ICON_PIXELS, TRAY_ICON_PIXELS)
		t.icon, t.color = icon, color
	}
	if connected := ui.session != nil; connected != t.connected || ui.hidden != t.hidden {
		tray_menu(ui)
	}
	if tray.step(t.handle) != 0 {
		log.warn("the tray icon is gone; carrying on without one")
		tray_hide(ui)
		t.refused = true
		return
	}

	request := t.request
	t.request = .None
	switch request {
	case .None:
	case .Show_Window:
		show_from_tray(ui)
	case .Toggle_Window:
		if ui.hidden {
			show_from_tray(ui)
		} else {
			hide_to_tray(ui)
		}
	case .Disconnect:
		// Picked up at the top of the next turn round the loop, rather
		// than while traycon is in the middle of a callback.
		log.debug("tray: disconnect")
		ui.action = .Disconnect
	case .Quit:
		log.debug("tray: quit")
		ui.quitting = true
	}
}

tray_show :: proc(ui: ^UI) {
	t := &ui.tray
	if t.handle != nil {
		return
	}
	icon, color := tray_state(ui)
	pixels := icon_rgba(icon, TRAY_ICON_PIXELS, color, context.temp_allocator)
	t.handle = tray.create(raw_data(pixels), TRAY_ICON_PIXELS, TRAY_ICON_PIXELS, tray_clicked, ui)
	if t.handle == nil {
		log.warn("this desktop has nowhere to put a tray icon")
		t.refused = true
		return
	}
	t.icon, t.color = icon, color
	tray_menu(ui)
	log.debug("tray icon shown")
}

tray_hide :: proc(ui: ^UI) {
	t := &ui.tray
	if t.handle == nil {
		return
	}
	tray.destroy(t.handle)
	t^ = {}
}

// What the icon should show, in the same order as the icon in front of
// your own name in the channel list.
@(private = "file")
tray_state :: proc(ui: ^UI) -> (Icon, mu.Color) {
	switch {
	case ui.deafened:
		return .Sound_Off, TRAY_OFF
	case ui.muted:
		return .Mic_Off, TRAY_OFF
	}
	speaking := false
	if ui.session != nil {
		sync.guard(&ui.view.mutex)
		speaking = is_speaking(&ui.view, ui.view.my_num)
	}
	return .Mic, TRAY_TALKING if speaking else TRAY_QUIET
}

// on_wayland reports whether we're running as a Wayland client, which
// decides what the desktop is able to tell us (see iconify_callback).
on_wayland :: proc() -> bool {
	when ODIN_OS == .Linux {
		return glfw.GetPlatform() == glfw.PLATFORM_WAYLAND
	} else {
		return false
	}
}

// tray_takes_window reports whether the window should go to the tray
// rather than do what it usually does: only where there's an icon to go
// to, and only if that's what the setting says.
tray_takes_window :: proc(ui: ^UI, setting: bool) -> bool {
	return setting && ui.tray.handle != nil
}

/*
hide_to_tray puts the window away, leaving the client running behind the
tray icon. Nothing is drawn while it's away (see run_ui), so a hidden
client costs next to nothing.

The window is closed rather than hidden. GLFW can hide one, but on
Wayland that unmaps the surface, and the EGL buffers behind it are then
never released: the next swap waits on the compositor for ever, which
looks exactly like the client freezing. Taking the window down and
building a new one has nothing left to wait on, and the client - the
connection, the voice, the tray icon - runs through it untouched. It
comes back the size it went away at, wherever the desktop decides to
put it.
*/
hide_to_tray :: proc(ui: ^UI) {
	if ui.hidden || ui.tray.handle == nil {
		return
	}
	ui.hidden = true
	window_close(ui)
	log.debug("hidden to the tray")
}

show_from_tray :: proc(ui: ^UI) {
	if !ui.hidden {
		return
	}
	ui.hidden = false
	if !window_open(ui) {
		// Nothing to show it in: better a client that's still there
		// than one that has quietly gone.
		log.error("could not open the window again")
		ui.hidden = true
		return
	}
	// Whether this actually raises the window is the desktop's call;
	// Wayland won't let a window take the focus for itself.
	glfw.RequestWindowAttention(ui.window)
	log.debug("back from the tray")
}

@(private = "file")
tray_menu :: proc(ui: ^UI) {
	t := &ui.tray
	t.connected = ui.session != nil
	t.hidden = ui.hidden
	items := [?]tray.Menu_Item {
		{label = "Show window" if t.hidden else "Hide window", id = MENU_WINDOW},
		{label = "Disconnect", id = MENU_DISCONNECT, flags = {} if t.connected else {.Disabled}},
		{label = nil, id = 0}, // a line between them
		{label = "Quit", id = MENU_QUIT},
	}
	tray.set_menu(t.handle, raw_data(items[:]), len(items), tray_menu_picked, ui)
}

@(private = "file")
tray_clicked :: proc "c" (handle: ^tray.Tray, userdata: rawptr) {
	ui := (^UI)(userdata)
	ui.tray.request = .Show_Window
}

@(private = "file")
tray_menu_picked :: proc "c" (handle: ^tray.Tray, item_id: i32, userdata: rawptr) {
	ui := (^UI)(userdata)
	switch item_id {
	case MENU_WINDOW:
		ui.tray.request = .Toggle_Window
	case MENU_DISCONNECT:
		ui.tray.request = .Disconnect
	case MENU_QUIT:
		ui.tray.request = .Quit
	}
}

/*
tray_notify shows a desktop notification, through the tray icon: traycon
has the desktop's notification service to hand once there's an icon.
Called on the UI thread, which is the one traycon runs on. False if
there's no icon to go through, or the desktop wouldn't take it.
*/
tray_notify :: proc(ui: ^UI, title, body: string) -> bool {
	t := &ui.tray
	if t.handle == nil {
		return false
	}
	ctitle := strings.clone_to_cstring(title, context.temp_allocator)
	cbody := strings.clone_to_cstring(body, context.temp_allocator) if body != "" else nil
	if tray.notify(t.handle, ctitle, cbody, nil, 0, nil, nil) != 0 {
		log.warn("tray: the desktop wouldn't show a notification")
		return false
	}
	return true
}
