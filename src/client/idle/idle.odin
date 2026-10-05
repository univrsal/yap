/*
Whether whoever uses this computer has been away from it: no input
anywhere on the desktop - not only in yap's window - for a while.

	open(after, wayland_display, x11_display) -> Source
	check() -> (idle, known)
	close()

Where it comes from:

	Windows   GetLastInputInfo
	macOS     CGEventSourceSecondsSinceLastEventType
	Wayland   the ext-idle-notify-v1 protocol (yap_idle.c)
	X11       the MIT-SCREEN-SAVER extension, libXss (yap_idle.c)
	web       the Idle Detection API, once the page has been allowed to
	          use it (ask); Chromium only

`known` is false where none of these is there (a Wayland compositor
without the protocol, a browser without the API or the permission); the
client then goes by input in its own window alone. Call everything from
the thread that runs the window.
*/
package idle

Source :: enum {
	None,
	Windows,
	Mac,
	Wayland,
	X11,
	Browser,
}
