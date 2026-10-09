#+build !wasi
package client

import glfw "client:wglfw"
import log "common:wlog"
import "core:math/linalg"
import "core:strings"
import "core:sync"
import mu "vendor:microui"

import "client:conn"
import "client:render"
import "client:tray"

/*
The tray icon: the window's icon in the system tray, and while we're in
voice a microphone instead, showing whether we're talking, muted or
deafened, with a right-click menu to disconnect or quit. The microphone
is drawn from the same shapes as the icons in the window (see
render/icons.odin), so the two always say the same thing. Either has a
dot in its corner while something is unread: red with mentions of us
(or DMs), blue with only other messages.

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
// The dot: something is unread (see unread_total), or some of it is for
// us.
@(private = "file")
TRAY_UNREAD :: mu.Color{80, 140, 235, 255}
@(private = "file")
TRAY_MENTIONS :: mu.Color{225, 60, 60, 255}

@(private = "file")
MENU_WINDOW :: 1
@(private = "file")
MENU_DISCONNECT :: 2
@(private = "file")
MENU_QUIT :: 3

// How many notifications a click can still be told apart for.
NOTICE_TARGETS :: 16

// What a click asked for, acted on after traycon is done stepping.
Tray_Request :: enum {
	None,
	Show_Window,
	Toggle_Window,
	Focus_Window, // a notification was clicked
	Disconnect,
	Quit,
}

Tray :: struct {
	handle:    ^tray.Tray,
	// What the icon is showing, so it's only redrawn when it changes.
	look:      Tray_Look,
	// What the menu was last built for: Disconnect is greyed out when
	// there's nothing to disconnect from, and the first item says
	// whether the window is to be shown or hidden.
	connected: bool,
	hidden:    bool,
	request:   Tray_Request,
	// Where the notifications shown lately go when clicked, kept in a ring
	// so a click (which only hands back a pointer into it) knows which one
	// it was; `clicked` is where the last click on one went.
	targets:   [NOTICE_TARGETS]Notice_Target,
	next:      int,
	clicked:   Notice_Target,
	// The desktop wouldn't take an icon, or took ours away again. We
	// stop asking until the setting is switched off and on, and leave
	// the setting alone: it's the user's, and their tray may well be
	// there the next time they start the client.
	refused:   bool,
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

	if look := tray_state(ui); look != t.look {
		pixels := tray_pixels(look)
		tray.update_icon(t.handle, raw_data(pixels), TRAY_ICON_PIXELS, TRAY_ICON_PIXELS)
		t.look = look
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
	if request != .None {
		ui_redraw(ui)
	}
	switch request {
	case .None:
	case .Show_Window:
		show_from_tray(ui)
	case .Focus_Window:
		focus_window(ui)
		clicked := t.clicked
		t.clicked = {}
		notice_open(ui, clicked)
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
		ui.action = .Close
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
	look := tray_state(ui)
	pixels := tray_pixels(look)
	t.handle = tray.create(raw_data(pixels), TRAY_ICON_PIXELS, TRAY_ICON_PIXELS, tray_clicked, ui)
	if t.handle == nil {
		log.warn("this desktop has nowhere to put a tray icon")
		t.refused = true
		return
	}
	t.look = look
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

// What the tray icon shows.
Tray_Look :: struct {
	// In voice (UI.voice_at): the microphone, as `icon` in `color`;
	// otherwise the window's icon.
	voice: bool,
	icon:  render.Icon,
	color: mu.Color,
	dot:   Tray_Dot,
}

Tray_Dot :: enum {
	None,
	Unread,
	Mentions,
}

/*
What the icon should show: in voice, the microphone, in the same order
as the icon in front of your own name in the channel list; and whether
there's a dot, for what's unread on every server (servers_frame).
*/
@(private = "file")
tray_state :: proc(ui: ^UI) -> (look: Tray_Look) {
	switch {
	case ui.mentions > 0:
		look.dot = .Mentions
	case ui.unread > 0:
		look.dot = .Unread
	}
	ns := ui.voice_at
	if ns == nil {
		return
	}
	look.voice = true
	switch {
	case ui.deafened:
		look.icon, look.color = .Sound_Off, TRAY_OFF
	case ui.muted:
		look.icon, look.color = .Mic_Off, TRAY_OFF
	case:
		v := &ns.view
		sync.guard(&v.mutex)
		speaking := conn.is_speaking(v, v.my_num)
		look.icon, look.color = .Mic, TRAY_TALKING if speaking else TRAY_QUIET
	}
	return
}

/*
tray_pixels draws `look` for the desktop, TRAY_ICON_PIXELS square, in
the frame's temp allocator. The dot sits in the bottom right corner with
a clear ring round it, so it stands apart from the picture under it.
*/
@(private = "file")
tray_pixels :: proc(look: Tray_Look) -> []u8 {
	side := TRAY_ICON_PIXELS
	pixels: []u8
	if !look.voice {
		pixels = window_icon_rgba(side, context.temp_allocator)
	}
	if pixels == nil {
		icon, color := look.icon, look.color
		if !look.voice {
			// The window's icon wouldn't decode.
			icon, color = .Mic, TRAY_QUIET
		}
		pixels = render.icon_rgba(icon, side, color, context.temp_allocator)
	}
	if look.dot == .None {
		return pixels
	}
	c := TRAY_MENTIONS if look.dot == .Mentions else TRAY_UNREAD
	color := [3]u8{c.r, c.g, c.b}
	radius := f32(side) * 0.2
	ring := f32(side) * 0.07
	center := [2]f32{f32(side) - radius - 0.5, f32(side) - radius - 0.5}
	for y in 0 ..< side {
		for x in 0 ..< side {
			d := linalg.distance([2]f32{f32(x) + 0.5, f32(y) + 0.5}, center) - radius
			i := (y * side + x) * 4
			// Cleared under the ring, fading back in past it.
			pixels[i + 3] = u8(f32(pixels[i + 3]) * clamp(d - ring + 0.5, 0, 1))
			// The dot, over whatever is left.
			cover := clamp(0.5 - d, 0, 1)
			if cover == 0 {
				continue
			}
			under := f32(pixels[i + 3]) / 255
			alpha := cover + under * (1 - cover)
			for k in 0 ..< 3 {
				top, bottom := f32(color[k]), f32(pixels[i + k])
				pixels[i + k] = u8((top * cover + bottom * under * (1 - cover)) / alpha)
			}
			pixels[i + 3] = u8(alpha * 255)
		}
	}
	return pixels
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

/*
focus_window brings the window to the front for a notification that was
clicked: back from the tray, up from being minimized, and given the
focus. Wayland won't let a window take the focus, and Windows may only
flash its button on the taskbar instead; either way it asks for
attention.
*/
@(private = "file")
focus_window :: proc(ui: ^UI) {
	if ui.hidden {
		show_from_tray(ui)
		return
	}
	if ui.window == nil {
		return
	}
	if glfw.WindowIconified(ui.window) {
		glfw.RestoreWindow(ui.window)
	}
	if on_wayland() {
		glfw.RequestWindowAttention(ui.window)
	} else {
		glfw.FocusWindow(ui.window)
	}
	log.debug("tray: notification clicked")
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

// A click on a notification, or on one of its buttons (it has none).
@(private = "file")
tray_notification_clicked :: proc "c" (handle: ^tray.Tray, action_id: cstring, userdata: rawptr) {
	target := (^Notice_Target)(userdata)
	ui := target.ui
	ui.tray.clicked = target^
	ui.tray.request = .Focus_Window
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
Called on the UI thread, which is the one traycon runs on. Clicking it
brings the window up (focus_window), and goes to `target`'s message
(notice_open) if it has one. False if there's no icon to go
through, or the desktop wouldn't take it.
*/
tray_notify :: proc(ui: ^UI, title, body: string, target := Notice_Target{}) -> bool {
	t := &ui.tray
	if t.handle == nil {
		return false
	}
	slot := &t.targets[t.next]
	t.next = (t.next + 1) % NOTICE_TARGETS
	slot^ = target
	slot.ui = ui
	ctitle := strings.clone_to_cstring(title, context.temp_allocator)
	cbody := strings.clone_to_cstring(body, context.temp_allocator) if body != "" else nil
	if tray.notify(t.handle, ctitle, cbody, nil, 0, tray_notification_clicked, slot) != 0 {
		log.warn("tray: the desktop wouldn't show a notification")
		return false
	}
	return true
}
