/*
 * Copyright (c) 2026, Alex <uni@vrsal.cc>
 * SPDX-License-Identifier: BSD-3-Clause
 */
/*
 * traycon.h normally calls into libdbus-1 and libX11 directly.
 * This shim makes that optional: it loads each
 * library with dlopen() instead, so a missing one just means that
 * backend (or desktop notifications) doesn't come up.
 *
 * #include this before traycon.h. Every dbus_ and X11
 * symbol traycon.h calls gets #defined here to go through a function pointer
 * we fill in with dlsym(); the pointer's type is pulled from the real
 * header with __typeof__, so it can't drift from what libdbus-1/libX11
 * actually export. traycon.h itself calls traycon_dl_have_dbus() /
 * traycon_dl_have_x11() before the first real call into either library
 * (see the "dlopen" comments there) -- that's the one piece of
 * traycon.h that isn't vendored unmodified.
 *
 * XDestroyImage and XPutPixel are deliberately left alone: with
 * XUTIL_DEFINE_FUNCTIONS undefined (the default), Xutil.h defines them
 * as macros that dispatch through the XImage's own function table
 * (filled in by XCreateImage()), not through a libX11 symbol -- dlsym
 * would never find them.
 */
#ifndef TRAYCON_DL_H
#define TRAYCON_DL_H

#include <dlfcn.h>

#if !defined(TRAYCON_NO_SNI) || !defined(TRAYCON_NO_NOTIFICATIONS)
#define TRAYCON_DL_HAS_DBUS 1
#include <dbus/dbus.h>
#endif

#ifndef TRAYCON_NO_X11
#define TRAYCON_DL_HAS_X11 1
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#endif

/* ------------------------------------------------------------------ */
/*  D-Bus                                                              */
/* ------------------------------------------------------------------ */

#ifdef TRAYCON_DL_HAS_DBUS

#define TRAYCON_DL_DBUS_SYMS(X) \
    X(dbus_bus_add_match) \
    X(dbus_bus_get) \
    X(dbus_bus_release_name) \
    X(dbus_bus_request_name) \
    X(dbus_connection_add_filter) \
    X(dbus_connection_dispatch) \
    X(dbus_connection_flush) \
    X(dbus_connection_read_write) \
    X(dbus_connection_register_object_path) \
    X(dbus_connection_remove_filter) \
    X(dbus_connection_send) \
    X(dbus_connection_send_with_reply_and_block) \
    X(dbus_connection_unref) \
    X(dbus_connection_unregister_object_path) \
    X(dbus_error_free) \
    X(dbus_error_init) \
    X(dbus_error_is_set) \
    X(dbus_message_append_args) \
    X(dbus_message_get_args) \
    X(dbus_message_get_interface) \
    X(dbus_message_is_method_call) \
    X(dbus_message_is_signal) \
    X(dbus_message_iter_append_basic) \
    X(dbus_message_iter_append_fixed_array) \
    X(dbus_message_iter_close_container) \
    X(dbus_message_iter_get_arg_type) \
    X(dbus_message_iter_get_basic) \
    X(dbus_message_iter_init) \
    X(dbus_message_iter_init_append) \
    X(dbus_message_iter_next) \
    X(dbus_message_iter_open_container) \
    X(dbus_message_iter_recurse) \
    X(dbus_message_new_error_printf) \
    X(dbus_message_new_method_call) \
    X(dbus_message_new_method_return) \
    X(dbus_message_new_signal) \
    X(dbus_message_unref)

#define TRAYCON_DL_PTR(name) static __typeof__(name) *p_##name;
TRAYCON_DL_DBUS_SYMS(TRAYCON_DL_PTR)
#undef TRAYCON_DL_PTR

#define dbus_bus_add_match (*p_dbus_bus_add_match)
#define dbus_bus_get (*p_dbus_bus_get)
#define dbus_bus_release_name (*p_dbus_bus_release_name)
#define dbus_bus_request_name (*p_dbus_bus_request_name)
#define dbus_connection_add_filter (*p_dbus_connection_add_filter)
#define dbus_connection_dispatch (*p_dbus_connection_dispatch)
#define dbus_connection_flush (*p_dbus_connection_flush)
#define dbus_connection_read_write (*p_dbus_connection_read_write)
#define dbus_connection_register_object_path (*p_dbus_connection_register_object_path)
#define dbus_connection_remove_filter (*p_dbus_connection_remove_filter)
#define dbus_connection_send (*p_dbus_connection_send)
#define dbus_connection_send_with_reply_and_block (*p_dbus_connection_send_with_reply_and_block)
#define dbus_connection_unref (*p_dbus_connection_unref)
#define dbus_connection_unregister_object_path (*p_dbus_connection_unregister_object_path)
#define dbus_error_free (*p_dbus_error_free)
#define dbus_error_init (*p_dbus_error_init)
#define dbus_error_is_set (*p_dbus_error_is_set)
#define dbus_message_append_args (*p_dbus_message_append_args)
#define dbus_message_get_args (*p_dbus_message_get_args)
#define dbus_message_get_interface (*p_dbus_message_get_interface)
#define dbus_message_is_method_call (*p_dbus_message_is_method_call)
#define dbus_message_is_signal (*p_dbus_message_is_signal)
#define dbus_message_iter_append_basic (*p_dbus_message_iter_append_basic)
#define dbus_message_iter_append_fixed_array (*p_dbus_message_iter_append_fixed_array)
#define dbus_message_iter_close_container (*p_dbus_message_iter_close_container)
#define dbus_message_iter_get_arg_type (*p_dbus_message_iter_get_arg_type)
#define dbus_message_iter_get_basic (*p_dbus_message_iter_get_basic)
#define dbus_message_iter_init (*p_dbus_message_iter_init)
#define dbus_message_iter_init_append (*p_dbus_message_iter_init_append)
#define dbus_message_iter_next (*p_dbus_message_iter_next)
#define dbus_message_iter_open_container (*p_dbus_message_iter_open_container)
#define dbus_message_iter_recurse (*p_dbus_message_iter_recurse)
#define dbus_message_new_error_printf (*p_dbus_message_new_error_printf)
#define dbus_message_new_method_call (*p_dbus_message_new_method_call)
#define dbus_message_new_method_return (*p_dbus_message_new_method_return)
#define dbus_message_new_signal (*p_dbus_message_new_signal)
#define dbus_message_unref (*p_dbus_message_unref)

/* -1 = not tried yet, 0 = tried and failed, 1 = loaded */
static int traycon_dl__dbus_state = -1;

/* Loads libdbus-1 and resolves every symbol above on first call; safe
 * to call as often as needed after that, from either backend. */
static int traycon_dl_have_dbus(void)
{
    if (traycon_dl__dbus_state >= 0) return traycon_dl__dbus_state;
    traycon_dl__dbus_state = 0;

    void *h = dlopen("libdbus-1.so.3", RTLD_NOW | RTLD_LOCAL);
    if (!h) h = dlopen("libdbus-1.so", RTLD_NOW | RTLD_LOCAL);
    if (!h) return 0;

#define TRAYCON_DL_LOAD(name) \
    if (!(p_##name = (__typeof__(p_##name))dlsym(h, #name))) goto fail;
    TRAYCON_DL_DBUS_SYMS(TRAYCON_DL_LOAD)
#undef TRAYCON_DL_LOAD

    traycon_dl__dbus_state = 1;
    return 1;

fail:
    dlclose(h);
    return 0;
}

#endif /* TRAYCON_DL_HAS_DBUS */

/* ------------------------------------------------------------------ */
/*  X11                                                                 */
/* ------------------------------------------------------------------ */

#ifdef TRAYCON_DL_HAS_X11

#define TRAYCON_DL_X11_SYMS(X) \
    X(XChangeProperty) \
    X(XCloseDisplay) \
    X(XCreateColormap) \
    X(XCreateGC) \
    X(XCreateImage) \
    X(XCreateWindow) \
    X(XDestroyWindow) \
    X(XDrawLine) \
    X(XDrawRectangle) \
    X(XDrawString) \
    X(XFillRectangle) \
    X(XFlush) \
    X(XFree) \
    X(XFreeColormap) \
    X(XFreeFont) \
    X(XFreeGC) \
    X(XGetSelectionOwner) \
    X(XGetVisualInfo) \
    X(XGetWindowAttributes) \
    X(XGetWindowProperty) \
    X(XGrabPointer) \
    X(XInternAtom) \
    X(XLoadQueryFont) \
    X(XMapRaised) \
    X(XNextEvent) \
    X(XOpenDisplay) \
    X(XPending) \
    X(XPutImage) \
    X(XSelectInput) \
    X(XSendEvent) \
    X(XSetFont) \
    X(XSetForeground) \
    X(XTextWidth) \
    X(XUngrabPointer)

#define TRAYCON_DL_PTR(name) static __typeof__(name) *p_##name;
TRAYCON_DL_X11_SYMS(TRAYCON_DL_PTR)
#undef TRAYCON_DL_PTR

#define XChangeProperty (*p_XChangeProperty)
#define XCloseDisplay (*p_XCloseDisplay)
#define XCreateColormap (*p_XCreateColormap)
#define XCreateGC (*p_XCreateGC)
#define XCreateImage (*p_XCreateImage)
#define XCreateWindow (*p_XCreateWindow)
#define XDestroyWindow (*p_XDestroyWindow)
#define XDrawLine (*p_XDrawLine)
#define XDrawRectangle (*p_XDrawRectangle)
#define XDrawString (*p_XDrawString)
#define XFillRectangle (*p_XFillRectangle)
#define XFlush (*p_XFlush)
#define XFree (*p_XFree)
#define XFreeColormap (*p_XFreeColormap)
#define XFreeFont (*p_XFreeFont)
#define XFreeGC (*p_XFreeGC)
#define XGetSelectionOwner (*p_XGetSelectionOwner)
#define XGetVisualInfo (*p_XGetVisualInfo)
#define XGetWindowAttributes (*p_XGetWindowAttributes)
#define XGetWindowProperty (*p_XGetWindowProperty)
#define XGrabPointer (*p_XGrabPointer)
#define XInternAtom (*p_XInternAtom)
#define XLoadQueryFont (*p_XLoadQueryFont)
#define XMapRaised (*p_XMapRaised)
#define XNextEvent (*p_XNextEvent)
#define XOpenDisplay (*p_XOpenDisplay)
#define XPending (*p_XPending)
#define XPutImage (*p_XPutImage)
#define XSelectInput (*p_XSelectInput)
#define XSendEvent (*p_XSendEvent)
#define XSetFont (*p_XSetFont)
#define XSetForeground (*p_XSetForeground)
#define XTextWidth (*p_XTextWidth)
#define XUngrabPointer (*p_XUngrabPointer)

static int traycon_dl__x11_state = -1; /* -1 untried, 0 failed, 1 loaded */

/* Loads libX11 and resolves every symbol above on first call. */
static int traycon_dl_have_x11(void)
{
    if (traycon_dl__x11_state >= 0) return traycon_dl__x11_state;
    traycon_dl__x11_state = 0;

    void *h = dlopen("libX11.so.6", RTLD_NOW | RTLD_LOCAL);
    if (!h) h = dlopen("libX11.so", RTLD_NOW | RTLD_LOCAL);
    if (!h) return 0;

#define TRAYCON_DL_LOAD(name) \
    if (!(p_##name = (__typeof__(p_##name))dlsym(h, #name))) goto fail;
    TRAYCON_DL_X11_SYMS(TRAYCON_DL_LOAD)
#undef TRAYCON_DL_LOAD

    traycon_dl__x11_state = 1;
    return 1;

fail:
    dlclose(h);
    return 0;
}

#endif /* TRAYCON_DL_HAS_X11 */

#endif /* TRAYCON_DL_H */
