#+build wasi
// The web half of the window layer: the GLFW implementation that emscripten
// provides on top of a canvas. Its entry points are ordinary C symbols, so they
// are declared here rather than imported as a module, and the few calls that
// make no sense for a page are stubbed out here instead.
package wglfw

WindowHandle :: distinct rawptr
MonitorHandle :: distinct rawptr
CursorHandle :: distinct rawptr

@(default_calling_convention = "c")
foreign _ {
	glfwInit :: proc() -> b32 ---
	glfwTerminate :: proc() ---
	glfwCreateWindow :: proc(width, height: i32, title: cstring, monitor: MonitorHandle, share: WindowHandle) -> WindowHandle ---
	glfwDestroyWindow :: proc(window: WindowHandle) ---
	glfwMakeContextCurrent :: proc(window: WindowHandle) ---
	glfwSwapBuffers :: proc(window: WindowHandle) ---
	glfwSwapInterval :: proc(interval: i32) ---
	glfwWindowHint :: proc(hint, value: i32) ---
	glfwPollEvents :: proc() ---
	glfwWindowShouldClose :: proc(window: WindowHandle) -> b32 ---
	glfwSetWindowShouldClose :: proc(window: WindowHandle, value: b32) ---
	glfwGetWindowSize :: proc(window: WindowHandle, width, height: ^i32) ---
	glfwSetWindowSize :: proc(window: WindowHandle, width, height: i32) ---
	glfwGetCursorPos :: proc(window: WindowHandle, x, y: ^f64) ---
	glfwSetErrorCallback :: proc(cb: proc "c" (code: i32, desc: cstring)) -> rawptr ---
	glfwSetKeyCallback :: proc(window: WindowHandle, cb: proc "c" (window: WindowHandle, key, scancode, action, mods: i32)) -> rawptr ---
	glfwSetCharCallback :: proc(window: WindowHandle, cb: proc "c" (window: WindowHandle, codepoint: rune)) -> rawptr ---
	glfwSetMouseButtonCallback :: proc(window: WindowHandle, cb: proc "c" (window: WindowHandle, button, action, mods: i32)) -> rawptr ---
	glfwSetCursorPosCallback :: proc(window: WindowHandle, cb: proc "c" (window: WindowHandle, x, y: f64)) -> rawptr ---
	glfwSetScrollCallback :: proc(window: WindowHandle, cb: proc "c" (window: WindowHandle, x, y: f64)) -> rawptr ---
	glfwGetClipboardString :: proc(window: WindowHandle) -> cstring ---
	glfwSetClipboardString :: proc(window: WindowHandle, text: cstring) ---
	// Sets the canvas' CSS cursor for a GLFW cursor shape, or the default
	// cursor for 0 (web/shell.c).
	yap_set_cursor :: proc(shape: i32) ---
}

Init :: proc "contextless" () -> b32 {return glfwInit()}
Terminate :: proc "contextless" () {glfwTerminate()}
CreateWindow :: proc "contextless" (
	width, height: i32,
	title: cstring,
	monitor: MonitorHandle,
	share: WindowHandle,
) -> WindowHandle {
	return glfwCreateWindow(width, height, title, monitor, share)
}
DestroyWindow :: proc "contextless" (window: WindowHandle) {glfwDestroyWindow(window)}
MakeContextCurrent :: proc "contextless" (window: WindowHandle) {glfwMakeContextCurrent(window)}
SwapBuffers :: proc "contextless" (window: WindowHandle) {glfwSwapBuffers(window)}
SwapInterval :: proc "contextless" (interval: i32) {glfwSwapInterval(interval)}
WindowShouldClose :: proc "contextless" (window: WindowHandle) -> b32 {
	return glfwWindowShouldClose(window)
}
SetWindowShouldClose :: proc "contextless" (window: WindowHandle, value: b32) {
	glfwSetWindowShouldClose(window, value)
}

WindowHint_int :: proc "contextless" (hint: i32, value: i32) {glfwWindowHint(hint, value)}
WindowHint_bool :: proc "contextless" (hint: i32, value: b32) {
	glfwWindowHint(hint, 1 if value else 0)
}
WindowHint :: proc {
	WindowHint_int,
	WindowHint_bool,
}

// The canvas' size in CSS pixels. The page sets it to fill the tab (see
// web_resize in main_web.odin).
SetWindowSize :: proc "contextless" (window: WindowHandle, width, height: i32) {
	glfwSetWindowSize(window, width, height)
}

GetWindowSize :: proc "c" (window: WindowHandle) -> (width, height: i32) {
	glfwGetWindowSize(window, &width, &height)
	return
}

@(default_calling_convention = "c")
foreign _ {
	// web/shell.c: sizes the canvas' backing store to the device pixels it
	// covers, and returns that size.
	yap_canvas_fit :: proc(width, height: ^i32) ---
	yap_device_pixel_ratio :: proc() -> f64 ---
	// web/shell.c: whether the page has the focus and is visible, and setting
	// its title.
	yap_page_focused :: proc() -> i32 ---
	yap_set_title :: proc(title: cstring) ---
}

// The window is the page, so it is focused when the page is.
WindowFocused :: proc "contextless" (window: WindowHandle) -> bool {
	return yap_page_focused() != 0
}

// The window's title is the tab's title.
SetWindowTitle :: proc "contextless" (window: WindowHandle, title: cstring) {
	yap_set_title(title)
}

// The size of the canvas' backing store, in device pixels. This doesn't use
// GLFW's own answer: GLFW sizes the canvas as floor(CSS size *
// devicePixelRatio), which with a fractional ratio can be a pixel off from what
// is on screen. So the page corrects it (yap_canvas_fit) every frame, since
// window_metrics asks every frame, and this returns the corrected size.
GetFramebufferSize :: proc "c" (window: WindowHandle) -> (width, height: i32) {
	yap_canvas_fit(&width, &height)
	return
}

// The page's devicePixelRatio: device pixels per CSS pixel (the window's size
// is in CSS pixels). It is asked of the page rather than calculated from the
// two sizes, which are whole pixels and so would give a slightly different
// ratio at every window size (1503 / 1002 = 1.5, but 1504 / 1003 isn't).
GetWindowContentScale :: proc "c" (window: WindowHandle) -> (xscale, yscale: f32) {
	ratio := f32(yap_device_pixel_ratio())
	return ratio, ratio
}

GetCursorPos :: proc "c" (window: WindowHandle) -> (x, y: f64) {
	glfwGetCursorPos(window, &x, &y)
	return
}

GetClipboardString :: proc "c" (window: WindowHandle) -> string {
	return string(glfwGetClipboardString(window))
}
SetClipboardString :: proc "c" (window: WindowHandle, text: cstring) {
	glfwSetClipboardString(window, text)
}

SetErrorCallback :: proc "contextless" (cb: proc "c" (code: i32, desc: cstring)) {
	glfwSetErrorCallback(cb)
}
SetKeyCallback :: proc "contextless" (
	window: WindowHandle,
	cb: proc "c" (window: WindowHandle, key, scancode, action, mods: i32),
) {glfwSetKeyCallback(window, cb)}
SetCharCallback :: proc "contextless" (
	window: WindowHandle,
	cb: proc "c" (window: WindowHandle, codepoint: rune),
) {glfwSetCharCallback(window, cb)}
SetMouseButtonCallback :: proc "contextless" (
	window: WindowHandle,
	cb: proc "c" (window: WindowHandle, button, action, mods: i32),
) {glfwSetMouseButtonCallback(window, cb)}
SetCursorPosCallback :: proc "contextless" (
	window: WindowHandle,
	cb: proc "c" (window: WindowHandle, x, y: f64),
) {glfwSetCursorPosCallback(window, cb)}
SetScrollCallback :: proc "contextless" (
	window: WindowHandle,
	cb: proc "c" (window: WindowHandle, x, y: f64),
) {glfwSetScrollCallback(window, cb)}

// Calls that make no sense for a page. The browser gives us one frame at a time
// and delivers input through the callbacks above, so there is nothing to wait
// for and nothing to wake up. The window is the canvas, so it can't be resized,
// restored or made to request attention from here, and there are no
// minimize events.
WaitEventsTimeout :: proc "contextless" (timeout: f64) {glfwPollEvents()}
PostEmptyEvent :: proc "contextless" () {}
SetWindowSizeLimits :: proc "contextless" (window: WindowHandle, minw, minh, maxw, maxh: i32) {}
RestoreWindow :: proc "contextless" (window: WindowHandle) {}
RequestWindowAttention :: proc "contextless" (window: WindowHandle) {}
SetWindowIconifyCallback :: proc "contextless" (
	window: WindowHandle,
	cb: proc "c" (window: WindowHandle, iconified: i32),
) {}
// A cursor is the canvas' CSS cursor, so the handle is just its shape.
CreateStandardCursor :: proc "contextless" (shape: i32) -> CursorHandle {
	return CursorHandle(uintptr(shape))
}
SetCursor :: proc "contextless" (window: WindowHandle, cursor: CursorHandle) {
	yap_set_cursor(i32(uintptr(cursor)))
}

// WebGL is linked in, so there are no function pointers to fetch.
gl_set_proc_address :: proc(p: rawptr, name: cstring) {}

GetPlatform :: proc "contextless" () -> i32 {return 0}
GetWaylandDisplay :: proc "contextless" () -> rawptr {return nil}
GetX11Display :: proc "contextless" () -> rawptr {return nil}

CONTEXT_VERSION_MAJOR :: 0x00022002
CONTEXT_VERSION_MINOR :: 0x00022003
OPENGL_PROFILE :: 0x00022008
OPENGL_CORE_PROFILE :: 0x00032001
OPENGL_FORWARD_COMPAT :: 0x00022006
SCALE_TO_MONITOR :: 0x0002200C
ALPHA_BITS :: 0x00021004
DONT_CARE :: -1

PRESS :: 1
RELEASE :: 0
REPEAT :: 2
MOD_SHIFT :: 0x0001
MOD_CONTROL :: 0x0002
MOD_ALT :: 0x0004
MOUSE_BUTTON_LEFT :: 0
MOUSE_BUTTON_RIGHT :: 1
MOUSE_BUTTON_MIDDLE :: 2
HAND_CURSOR :: 0x00036004
IBEAM_CURSOR :: 0x00036002
RESIZE_EW_CURSOR :: 0x00036005
RESIZE_NS_CURSOR :: 0x00036006
RESIZE_NWSE_CURSOR :: 0x00036007
RESIZE_NESW_CURSOR :: 0x00036008
PLATFORM_WAYLAND :: 0x00060003
PLATFORM_X11 :: 0x00060004

KEY_A :: 65
KEY_B :: 66
KEY_E :: 69
KEY_I :: 73
KEY_U :: 85
KEY_C :: 67
KEY_V :: 86
KEY_X :: 88
KEY_ESCAPE :: 256
KEY_ENTER :: 257
KEY_BACKSPACE :: 259
KEY_DELETE :: 261
KEY_RIGHT :: 262
KEY_UP :: 265
KEY_DOWN :: 264
KEY_TAB :: 258
KEY_LEFT :: 263
KEY_HOME :: 268
KEY_END :: 269
KEY_KP_ENTER :: 335
KEY_LEFT_SHIFT :: 340
KEY_LEFT_CONTROL :: 341
KEY_LEFT_ALT :: 342
KEY_RIGHT_SHIFT :: 344
KEY_RIGHT_CONTROL :: 345
KEY_RIGHT_ALT :: 346
