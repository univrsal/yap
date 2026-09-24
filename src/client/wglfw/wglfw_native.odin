#+build !wasi
/*
The window and input, as the client uses it.

A desktop build is GLFW itself. A web build is the GLFW that emscripten
puts in front of a canvas, which is linked in like any other C library
rather than imported as a module - so vendor:glfw can't be used there,
and the same entry points are declared by hand instead (see
wglfw_web.odin).

The client imports this package under the name `glfw`, so the calls
themselves read the same either way. Only what the client uses is here.
*/
package wglfw

import glfw "vendor:glfw"

WindowHandle :: glfw.WindowHandle
MonitorHandle :: glfw.MonitorHandle
CursorHandle :: glfw.CursorHandle

Init :: glfw.Init
Terminate :: glfw.Terminate
CreateWindow :: glfw.CreateWindow
DestroyWindow :: glfw.DestroyWindow
MakeContextCurrent :: glfw.MakeContextCurrent
SwapBuffers :: glfw.SwapBuffers
SwapInterval :: glfw.SwapInterval
WaitEventsTimeout :: glfw.WaitEventsTimeout
PostEmptyEvent :: glfw.PostEmptyEvent
WindowShouldClose :: glfw.WindowShouldClose
SetWindowShouldClose :: glfw.SetWindowShouldClose
WindowHint :: glfw.WindowHint
SetWindowSizeLimits :: glfw.SetWindowSizeLimits
SetWindowSize :: glfw.SetWindowSize
GetWindowSize :: glfw.GetWindowSize
GetFramebufferSize :: glfw.GetFramebufferSize
GetWindowContentScale :: glfw.GetWindowContentScale
GetCursorPos :: glfw.GetCursorPos
GetClipboardString :: glfw.GetClipboardString
SetClipboardString :: glfw.SetClipboardString
CreateStandardCursor :: glfw.CreateStandardCursor
SetCursor :: glfw.SetCursor
RequestWindowAttention :: glfw.RequestWindowAttention
RestoreWindow :: glfw.RestoreWindow
GetPlatform :: glfw.GetPlatform
GetPrimaryMonitor :: glfw.GetPrimaryMonitor
GetVideoMode :: glfw.GetVideoMode
gl_set_proc_address :: glfw.gl_set_proc_address
SetErrorCallback :: glfw.SetErrorCallback
SetKeyCallback :: glfw.SetKeyCallback
SetCharCallback :: glfw.SetCharCallback
SetCursorPosCallback :: glfw.SetCursorPosCallback
SetMouseButtonCallback :: glfw.SetMouseButtonCallback
SetScrollCallback :: glfw.SetScrollCallback
SetWindowIconifyCallback :: glfw.SetWindowIconifyCallback

CONTEXT_VERSION_MAJOR :: glfw.CONTEXT_VERSION_MAJOR
CONTEXT_VERSION_MINOR :: glfw.CONTEXT_VERSION_MINOR
OPENGL_PROFILE :: glfw.OPENGL_PROFILE
OPENGL_CORE_PROFILE :: glfw.OPENGL_CORE_PROFILE
OPENGL_FORWARD_COMPAT :: glfw.OPENGL_FORWARD_COMPAT
SCALE_TO_MONITOR :: glfw.SCALE_TO_MONITOR
DONT_CARE :: glfw.DONT_CARE
PRESS :: glfw.PRESS
RELEASE :: glfw.RELEASE
REPEAT :: glfw.REPEAT
MOUSE_BUTTON_LEFT :: glfw.MOUSE_BUTTON_LEFT
MOUSE_BUTTON_RIGHT :: glfw.MOUSE_BUTTON_RIGHT
MOUSE_BUTTON_MIDDLE :: glfw.MOUSE_BUTTON_MIDDLE
HAND_CURSOR :: glfw.HAND_CURSOR
PLATFORM_WAYLAND :: glfw.PLATFORM_WAYLAND
KEY_A :: glfw.KEY_A
KEY_BACKSPACE :: glfw.KEY_BACKSPACE
KEY_C :: glfw.KEY_C
KEY_DELETE :: glfw.KEY_DELETE
KEY_END :: glfw.KEY_END
KEY_ENTER :: glfw.KEY_ENTER
KEY_ESCAPE :: glfw.KEY_ESCAPE
KEY_HOME :: glfw.KEY_HOME
KEY_KP_ENTER :: glfw.KEY_KP_ENTER
KEY_LEFT :: glfw.KEY_LEFT
KEY_LEFT_ALT :: glfw.KEY_LEFT_ALT
KEY_LEFT_CONTROL :: glfw.KEY_LEFT_CONTROL
KEY_LEFT_SHIFT :: glfw.KEY_LEFT_SHIFT
KEY_RIGHT :: glfw.KEY_RIGHT
KEY_RIGHT_ALT :: glfw.KEY_RIGHT_ALT
KEY_RIGHT_CONTROL :: glfw.KEY_RIGHT_CONTROL
KEY_RIGHT_SHIFT :: glfw.KEY_RIGHT_SHIFT
KEY_V :: glfw.KEY_V
KEY_X :: glfw.KEY_X

// Wayland only, and only on a desktop: the clipboard needs GLFW's own
// connection to read anything (see clipboard_init).
GetWaylandDisplay :: proc "contextless" () -> rawptr {
	when ODIN_OS == .Linux {
		return glfw.GetWaylandDisplay()
	} else {
		return nil
	}
}
