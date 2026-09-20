/*
traycon (traycon.h, BSD-3-Clause), the tray icon library, compiled as
one translation unit for yap. The header is used unmodified; this file
is only here to hold its implementation.

On Linux the StatusNotifierItem backend talks to D-Bus (Wayland, KDE,
most modern desktops) and the X11 backend to an XEmbed tray, so both
libdbus-1 and libX11 are linked; traycon picks whichever the desktop
offers (see tray.odin). On macOS this is built as Objective-C, since
the implementation is Cocoa.
*/
#define TRAYCON_IMPLEMENTATION
#include "traycon.h"
