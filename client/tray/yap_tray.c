/*
traycon (traycon.h, BSD-3-Clause), the tray icon library, compiled as
one translation unit for yap. The header is used as close to unmodified
as possible (see traycon_dl.h and the "yap fork" note in traycon.h);
this file is only here to hold its implementation.

On Linux the StatusNotifierItem backend talks to D-Bus (Wayland, KDE,
most modern desktops) and the X11 backend to an XEmbed tray; traycon
picks whichever the desktop offers (see tray.odin). Neither libdbus-1
nor libX11 is linked at build time -- traycon_dl.h loads each with
dlopen() instead, so a desktop missing one just loses that backend
rather than refusing to start yap-client at all. On macOS this is
built as Objective-C, since the implementation is Cocoa.
*/
#if !defined(__APPLE__) && !defined(_WIN32)
#include "traycon_dl.h"
#endif
#define TRAYCON_IMPLEMENTATION
#include "traycon.h"
