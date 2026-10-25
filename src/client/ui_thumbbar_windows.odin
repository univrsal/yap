package client

import glfw "client:wglfw"
import log "common:wlog"
import win "core:sys/windows"
import "core:unicode/utf16"
import mu "vendor:microui"

import "client:render"

// Mute and deafen buttons under the window's thumbnail, in the preview that
// the taskbar shows when the pointer rests on the window's button (Windows'
// "thumbnail toolbar"). They do the same as the buttons in the voice panel,
// and are there whether or not we are in voice: mute and deafen carry over to
// the next call.
//
// The taskbar tells the window about a press with WM_COMMAND, which GLFW has no
// use for. So the window gets a window procedure of ours that records the
// press and passes everything else on, and the loop acts on it in
// thumbbar_update, as the tray does with its clicks. Ours is installed first,
// before titlebar_merge puts its own in front of it, so that the title bar can
// come and go without taking ours with it.
//
// The buttons can only be added once the taskbar has a button for the window,
// which it announces with a "TaskbarButtonCreated" message. That message
// arrives while GLFW is still showing the window, before our procedure is in
// place to see it, so the first attempt doesn't wait for it. It arrives again
// whenever Explorer restarts, which loses the buttons.

@(private = "file")
THUMB_MUTE :: 0
@(private = "file")
THUMB_DEAFEN :: 1

// What the taskbar puts in the high word of WM_COMMAND for a press.
@(private = "file")
THBN_CLICKED :: 0x1800

// The colours of the tray icon (ui_tray.odin): the preview sits on the
// taskbar's own colour, which may be light or dark.
@(private = "file")
THUMB_ON :: mu.Color{140, 148, 160, 255}
@(private = "file")
THUMB_OFF :: mu.Color{225, 80, 80, 255}

// What the buttons are showing, so they are only updated when it changes.
@(private = "file")
Thumb_Look :: struct {
	muted:    bool,
	deafened: bool,
}

@(private = "file")
Thumbbar :: struct {
	taskbar:   ^win.ITaskbarList3,
	// The number of the "TaskbarButtonCreated" message.
	created:   win.UINT,
	// The window the buttons are on, and the procedure that ours passes messages on to.
	hwnd:      win.HWND,
	next_proc: win.WNDPROC,
	// One of each picture, at the window's small icon size.
	mic:       win.HICON,
	mic_off:   win.HICON,
	sound:     win.HICON,
	sound_off: win.HICON,
	// Whether the buttons are on the window's taskbar button.
	added:     bool,
	// Adding them failed. Wait for a new taskbar button to try again.
	waiting:   bool,
	look:      Thumb_Look,
	// Presses since the last frame.
	mute:      bool,
	deafen:    bool,
}

// There is only one window, and the window procedure has nowhere else to look.
@(private = "file")
g_thumbs: Thumbbar

@(private = "file")
thumb_proc :: proc "system" (
	hwnd: win.HWND,
	msg: win.UINT,
	wparam: win.WPARAM,
	lparam: win.LPARAM,
) -> win.LRESULT {
	switch {
	case msg == g_thumbs.created && msg != 0:
		// A new taskbar button, which doesn't have any of our buttons yet.
		g_thumbs.added, g_thumbs.waiting = false, false
	case msg == win.WM_COMMAND && win.HIWORD(wparam) == THBN_CLICKED:
		switch win.LOWORD(wparam) {
		case THUMB_MUTE:
			g_thumbs.mute = true
		case THUMB_DEAFEN:
			g_thumbs.deafen = true
		}
		return 0
	}
	return win.CallWindowProcW(g_thumbs.next_proc, hwnd, msg, wparam, lparam)
}

// thumbbar_attach puts the buttons on a new window, or tries to. A desktop
// without a taskbar to put them on goes without them and says so in the log.
// Called from window_open, before titlebar_merge.
thumbbar_attach :: proc(window: glfw.WindowHandle) {
	t := &g_thumbs
	hwnd := win.HWND(glfw.GetWin32Window(window))
	if hwnd == nil {
		return
	}
	if t.taskbar == nil {
		// Already set up on this thread is just as good.
		win.CoInitializeEx(nil, .APARTMENTTHREADED)
		hr := win.CoCreateInstance(
			win.CLSID_TaskbarList,
			nil,
			win.CLSCTX_INPROC_SERVER,
			win.IID_ITaskbarList3,
			cast(^win.LPVOID)&t.taskbar,
		)
		if win.FAILED(hr) {
			log.warnf("no taskbar to put the mute buttons on (0x%x)", u32(hr))
			t.taskbar = nil
			return
		}
		if win.FAILED(t.taskbar->HrInit()) {
			log.warn("the taskbar wouldn't take the mute buttons")
			t.taskbar->Release()
			t.taskbar = nil
			return
		}
		t.created = win.RegisterWindowMessageW(win.L("TaskbarButtonCreated"))
	}
	t.hwnd = hwnd
	previous := win.SetWindowLongPtrW(
		hwnd,
		win.GWLP_WNDPROC,
		win.LONG_PTR(uintptr(rawptr(thumb_proc))),
	)
	t.next_proc = cast(win.WNDPROC)rawptr(uintptr(previous))

	side := int(win.GetSystemMetricsForDpi(win.SM_CXSMICON, win.GetDpiForWindow(hwnd)))
	t.mic = thumb_icon(.Mic, THUMB_ON, side)
	t.mic_off = thumb_icon(.Mic_Off, THUMB_OFF, side)
	t.sound = thumb_icon(.Sound, THUMB_ON, side)
	t.sound_off = thumb_icon(.Sound_Off, THUMB_OFF, side)
	t.added, t.waiting = false, false
}

// thumbbar_detach releases the window, which is about to be destroyed.
thumbbar_detach :: proc() {
	t := &g_thumbs
	for icon in ([?]win.HICON{t.mic, t.mic_off, t.sound, t.sound_off}) {
		if icon != nil {
			win.DestroyIcon(icon)
		}
	}
	t.hwnd, t.next_proc = nil, nil
	t.mic, t.mic_off, t.sound, t.sound_off = nil, nil, nil, nil
	t.added, t.waiting = false, false
	t.mute, t.deafen = false, false
}

// thumbbar_update acts on the button presses and keeps the buttons showing
// the current state. Called once a frame.
thumbbar_update :: proc(ui: ^UI) {
	t := &g_thumbs
	if t.mute {
		t.mute = false
		set_muted(ui, !ui.muted)
		ui_redraw(ui)
	}
	if t.deafen {
		t.deafen = false
		set_deafened(ui, !ui.deafened)
		ui_redraw(ui)
	}
	if t.hwnd == nil || t.taskbar == nil {
		return
	}

	look := Thumb_Look {
		muted    = ui.muted,
		deafened = ui.deafened,
	}
	switch {
	case !t.added && !t.waiting:
		buttons := thumb_buttons(look)
		hr := t.taskbar->ThumbBarAddButtons(t.hwnd, len(buttons), &buttons[0])
		t.added = win.SUCCEEDED(hr)
		t.waiting = !t.added
		if t.waiting {
			// Most likely too soon: TaskbarButtonCreated will arrive.
			log.debugf("taskbar: no buttons yet (0x%x)", u32(hr))
		}
	case t.added && look != t.look:
		buttons := thumb_buttons(look)
		if win.FAILED(t.taskbar->ThumbBarUpdateButtons(t.hwnd, len(buttons), &buttons[0])) {
			log.debug("taskbar: the buttons wouldn't update")
		}
	case:
		return
	}
	t.look = look
}

@(private = "file")
thumb_buttons :: proc(look: Thumb_Look) -> (buttons: [2]win.THUMBBUTTON) {
	t := &g_thumbs
	mask := win.THUMBBUTTONMASK(
		i32(win.THUMBBUTTONMASK.ICON) |
		i32(win.THUMBBUTTONMASK.TOOLTIP) |
		i32(win.THUMBBUTTONMASK.FLAGS),
	)
	buttons[THUMB_MUTE] = {
		dwMask  = mask,
		iId     = THUMB_MUTE,
		hIcon   = t.mic_off if look.muted else t.mic,
		dwFlags = .ENABLED,
	}
	utf16.encode_string(buttons[THUMB_MUTE].szTip[:259], "Unmute" if look.muted else "Mute")

	buttons[THUMB_DEAFEN] = {
		dwMask  = mask,
		iId     = THUMB_DEAFEN,
		hIcon   = t.sound_off if look.deafened else t.sound,
		dwFlags = .ENABLED,
	}
	utf16.encode_string(
		buttons[THUMB_DEAFEN].szTip[:259],
		"Undeafen" if look.deafened else "Deafen",
	)
	return
}

// thumb_icon draws `icon` `side` pixels square as an icon for a button. It is
// nil if Windows can't create one, which leaves the button blank.
@(private = "file")
thumb_icon :: proc(icon: render.Icon, color: mu.Color, side: int) -> win.HICON {
	pixels := render.icon_rgba(icon, side, color, context.temp_allocator)
	// GDI's pixels are BGRA.
	for i := 0; i < len(pixels); i += 4 {
		pixels[i], pixels[i + 2] = pixels[i + 2], pixels[i]
	}
	colour := win.CreateBitmap(i32(side), i32(side), 1, 32, raw_data(pixels))
	// With an alpha channel the mask goes unused, but one is still required:
	// one bit per pixel, with rows padded to two bytes.
	mask_bits := make([]u8, (side + 15) / 16 * 2 * side, context.temp_allocator)
	mask := win.CreateBitmap(i32(side), i32(side), 1, 1, raw_data(mask_bits))
	defer win.DeleteObject(win.HGDIOBJ(colour))
	defer win.DeleteObject(win.HGDIOBJ(mask))
	info := win.ICONINFO {
		fIcon    = true,
		hbmMask  = mask,
		hbmColor = colour,
	}
	return win.CreateIconIndirect(&info)
}
