package client

import glfw "client:wglfw"
import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"
foreign import user32 "system:User32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	GetTickCount :: proc() -> win.DWORD ---
}

@(default_calling_convention = "system")
foreign user32 {
	GetDoubleClickTime :: proc() -> win.UINT ---
}

// On Windows the window has no title bar of its own either: the UI runs up to
// the top edge, with minimize, maximize and close buttons of its own at the end
// of the first row (see title_row). The frame is still the system's, so
// resizing, snapping and the window menu behave as usual. Only its client area
// has grown to cover the title bar, and DWM draws nothing in it.
//
// What is left of the strip that the title bar used to be still moves the
// window when dragged and maximizes it when double-clicked, wherever there is
// no control of ours under the pointer (see mouse_button_callback).

// Room left between the first row and the buttons, in pixels.
@(private = "file")
TITLEBAR_GAP :: 8

// The window procedure that GLFW installed, which ours passes messages on to.
@(private = "file")
g_glfw_proc: win.WNDPROC

// When the last press on the strip happened, to tell a double click.
@(private = "file")
g_last_press: win.DWORD

// How thick the sizing frame is, in pixels.
@(private = "file")
frame_size :: proc "contextless" (hwnd: win.HWND) -> (x, y: i32) {
	dpi := win.GetDpiForWindow(hwnd)
	padded := win.GetSystemMetricsForDpi(win.SM_CXPADDEDBORDER, dpi)
	x = win.GetSystemMetricsForDpi(win.SM_CXFRAME, dpi) + padded
	y = win.GetSystemMetricsForDpi(win.SM_CYFRAME, dpi) + padded
	return
}

@(private = "file")
title_proc :: proc "system" (
	hwnd: win.HWND,
	msg: win.UINT,
	wparam: win.WPARAM,
	lparam: win.LPARAM,
) -> win.LRESULT {
	switch msg {
	case win.WM_NCCALCSIZE:
		if wparam == 0 {
			break
		}
		// The client area is the whole window. When maximized, the window
		// overhangs the screen by the frame, which stays off it.
		if win.IsZoomed(hwnd) {
			params := cast(^win.NCCALCSIZE_PARAMS)uintptr(lparam)
			fx, fy := frame_size(hwnd)
			params.rgrc[0].left += fx
			params.rgrc[0].right -= fx
			params.rgrc[0].top += fy
			params.rgrc[0].bottom -= fy
		}
		return 0
	case win.WM_NCHITTEST:
		hit := win.CallWindowProcW(g_glfw_proc, hwnd, msg, wparam, lparam)
		if hit != win.HTCLIENT || win.IsZoomed(hwnd) {
			return hit
		}
		// With no frame left outside the client area, the sizing borders are
		// the outer edge of it.
		rect: win.RECT
		win.GetWindowRect(hwnd, &rect)
		x := i32(i16(lparam & 0xFFFF))
		y := i32(i16((lparam >> 16) & 0xFFFF))
		fx, fy := frame_size(hwnd)
		left := x < rect.left + fx
		right := x >= rect.right - fx
		top := y < rect.top + fy
		bottom := y >= rect.bottom - fy
		switch {
		case top && left:
			return win.HTTOPLEFT
		case top && right:
			return win.HTTOPRIGHT
		case bottom && left:
			return win.HTBOTTOMLEFT
		case bottom && right:
			return win.HTBOTTOMRIGHT
		case top:
			return win.HTTOP
		case bottom:
			return win.HTBOTTOM
		case left:
			return win.HTLEFT
		case right:
			return win.HTRIGHT
		}
		return hit
	}
	return win.CallWindowProcW(g_glfw_proc, hwnd, msg, wparam, lparam)
}

// titlebar_merge lets the UI take the title bar's place, or gives it back.
// Called once each window has its rendering set up (hiding to the tray takes
// the window down, and the one that comes back is a new one), and when the
// setting changes.
titlebar_merge :: proc(window: glfw.WindowHandle, merged: bool) {
	hwnd := win.HWND(glfw.GetWin32Window(window))
	if hwnd == nil || merged == is_merged(hwnd) {
		return
	}
	margins: win.MARGINS
	if merged {
		previous := win.SetWindowLongPtrW(hwnd, win.GWLP_WNDPROC, our_proc())
		g_glfw_proc = cast(win.WNDPROC)rawptr(uintptr(previous))
		// A sliver of frame keeps the shadow around the window.
		margins = {0, 0, 1, 0}
	} else {
		win.SetWindowLongPtrW(hwnd, win.GWLP_WNDPROC, win.LONG_PTR(uintptr(rawptr(g_glfw_proc))))
	}
	win.DwmExtendFrameIntoClientArea(hwnd, &margins)
	win.SetWindowPos(
		hwnd,
		nil,
		0,
		0,
		0,
		0,
		win.SWP_FRAMECHANGED |
		win.SWP_NOMOVE |
		win.SWP_NOSIZE |
		win.SWP_NOZORDER |
		win.SWP_NOACTIVATE,
	)
}

@(private = "file")
our_proc :: proc() -> win.LONG_PTR {
	return win.LONG_PTR(uintptr(rawptr(title_proc)))
}

// is_merged reports whether the window has our window procedure, which does
// the merging.
@(private = "file")
is_merged :: proc(hwnd: win.HWND) -> bool {
	return win.GetWindowLongPtrW(hwnd, win.GWLP_WNDPROC) == our_proc()
}

// titlebar_area is the strip along the top that the title bar would have
// taken, in window coordinates: how far in from the left and from the right
// the window's own buttons reach (only the right here), and how tall the strip
// is. It is zero in fullscreen, where there is no title bar.
titlebar_area :: proc(ui: ^UI) -> (left, right, height: f32) {
	hwnd := win.HWND(glfw.GetWin32Window(ui.window))
	if hwnd == nil || !is_merged(hwnd) {
		return
	}
	if u32(win.GetWindowLongW(hwnd, win.GWL_STYLE)) & win.WS_CAPTION != win.WS_CAPTION {
		return
	}
	dpi := win.GetDpiForWindow(hwnd)
	height = f32(win.GetSystemMetricsForDpi(win.SM_CYCAPTION, dpi))
	right = f32(TITLEBAR_BUTTON_WIDTH * TITLEBAR_BUTTON_COUNT * i32(dpi) / 96) + TITLEBAR_GAP
	return
}

// titlebar_buttons draws the window's buttons in the top right corner of the
// window, `w` wide, in the strip that titlebar_area made room for, and does
// what they say when pressed.
titlebar_buttons :: proc(ui: ^UI, w: i32) {
	if ui.titlebar_right == 0 {
		return
	}
	hwnd := win.HWND(glfw.GetWin32Window(ui.window))
	maximized := bool(win.IsZoomed(hwnd))
	switch window_buttons(ui, w, TITLEBAR_GAP, maximized) {
	case 0:
		win.ShowWindow(hwnd, win.SW_MINIMIZE)
	case 1:
		win.ShowWindow(hwnd, win.SW_RESTORE if maximized else win.SW_MAXIMIZE)
	case 2:
		win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0)
	}
}

// titlebar_press does what a title bar does with the press being handled:
// move the window along with the pointer, or maximize or restore it on a
// double click. Called from the mouse button callback. The drag runs until the
// button is released.
titlebar_press :: proc(window: glfw.WindowHandle) {
	hwnd := win.HWND(glfw.GetWin32Window(window))
	if hwnd == nil {
		return
	}
	now := GetTickCount()
	if now - g_last_press < GetDoubleClickTime() {
		g_last_press = 0
		win.ShowWindow(hwnd, win.SW_RESTORE if win.IsZoomed(hwnd) else win.SW_MAXIMIZE)
		return
	}
	g_last_press = now
	pos: win.POINT
	win.GetCursorPos(&pos)
	win.ReleaseCapture()
	win.SendMessageW(
		hwnd,
		win.WM_NCLBUTTONDOWN,
		win.HTCAPTION,
		win.LPARAM(u32(u16(pos.x)) | u32(u16(pos.y)) << 16),
	)
}

// The frame stays the system's, sizing borders and all (see title_proc).
titlebar_init :: proc(merged: bool) {}

titlebar_window_hints :: proc(merged: bool) {}

titlebar_motion :: proc(window: glfw.WindowHandle) {}

titlebar_resizable :: proc(window: glfw.WindowHandle) -> bool {
	return false
}

titlebar_resize :: proc(window: glfw.WindowHandle, edge: Window_Edge) {}

titlebar_restart_note :: proc(merged: bool) -> string {
	return ""
}
