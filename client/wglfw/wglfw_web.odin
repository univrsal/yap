#+build wasi
/*
The web half of the window layer: the GLFW that emscripten puts in
front of a canvas. Its entry points are ordinary C symbols, so they're
declared here rather than imported as a module, and the few things a
page has no answer for are answered here instead.
*/
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

// The canvas' size in CSS pixels; the page sets it to fill the tab (see
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
	// web/shell.c: sizes the canvas' backing store to the device pixels
	// it covers, and returns that size.
	yap_canvas_fit :: proc(width, height: ^i32) ---
	yap_device_pixel_ratio :: proc() -> f64 ---
}

// The canvas' backing store, in device pixels. Not GLFW's own answer:
// it sizes the canvas as floor(CSS size * devicePixelRatio), which a
// fractional ratio makes a pixel off what's on screen, so the page puts
// that right (yap_canvas_fit) - every frame, since window_metrics asks
// every frame - and this is the size that results.
GetFramebufferSize :: proc "c" (window: WindowHandle) -> (width, height: i32) {
	yap_canvas_fit(&width, &height)
	return
}

// The page's devicePixelRatio: device pixels per CSS pixel, which the
// window's size is in. Asked of the page rather than worked out from the
// two sizes, which come in whole pixels and so give a slightly different
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

/*
Things a page has no answer for. The browser hands us a frame at a time
and delivers input through the callbacks above, so there is nothing to
wait for and nothing to wake up; the window is the canvas, so it can't
be resized, restored or asked for attention from in here; and there is
no minimizing to hear about.
*/
WaitEventsTimeout :: proc "contextless" (timeout: f64) {glfwPollEvents()}
PostEmptyEvent :: proc "contextless" () {}
SetWindowSizeLimits :: proc "contextless" (window: WindowHandle, minw, minh, maxw, maxh: i32) {}
RestoreWindow :: proc "contextless" (window: WindowHandle) {}
RequestWindowAttention :: proc "contextless" (window: WindowHandle) {}
SetWindowIconifyCallback :: proc "contextless" (
	window: WindowHandle,
	cb: proc "c" (window: WindowHandle, iconified: i32),
) {}
CreateStandardCursor :: proc "contextless" (shape: i32) -> CursorHandle {return nil}
SetCursor :: proc "contextless" (window: WindowHandle, cursor: CursorHandle) {}

// WebGL is linked in, so there are no function pointers to fetch.
gl_set_proc_address :: proc(p: rawptr, name: cstring) {}

GetPlatform :: proc "contextless" () -> i32 {return 0}
GetWaylandDisplay :: proc "contextless" () -> rawptr {return nil}

CONTEXT_VERSION_MAJOR :: 0x00022002
CONTEXT_VERSION_MINOR :: 0x00022003
OPENGL_PROFILE :: 0x00022008
OPENGL_CORE_PROFILE :: 0x00032001
OPENGL_FORWARD_COMPAT :: 0x00022006
SCALE_TO_MONITOR :: 0x0002200C
DONT_CARE :: -1

PRESS :: 1
RELEASE :: 0
REPEAT :: 2
MOUSE_BUTTON_LEFT :: 0
MOUSE_BUTTON_RIGHT :: 1
MOUSE_BUTTON_MIDDLE :: 2
HAND_CURSOR :: 0x00036004
PLATFORM_WAYLAND :: 0x00060003

KEY_A :: 65
KEY_C :: 67
KEY_V :: 86
KEY_X :: 88
KEY_ESCAPE :: 256
KEY_ENTER :: 257
KEY_BACKSPACE :: 259
KEY_DELETE :: 261
KEY_RIGHT :: 262
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
