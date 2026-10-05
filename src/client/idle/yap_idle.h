#ifndef YAP_IDLE_H
#define YAP_IDLE_H

/* What yap_idle_open found to ask (see yap_idle.c). */
#define YAP_IDLE_NONE 0
#define YAP_IDLE_WAYLAND 1
#define YAP_IDLE_X11 2

/* Starts watching for after_ms without input on the desktop the window
   is on: its wl_display, or failing that its X11 Display. */
int yap_idle_open(void *wayland_display, void *x11_display, unsigned after_ms);
/* 1 idle, 0 not, -1 can't tell. */
int yap_idle_check(void);
void yap_idle_close(void);

#endif
