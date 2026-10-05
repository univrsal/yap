/*
How long since the last input anywhere on the desktop, on Linux and the
BSDs (see idle.odin). Two ways, whichever the window is on:

- Wayland: the ext-idle-notify-v1 protocol. The compositor says when
  the seat has had no input for a given time (idled) and when it has
  again (resumed); the events come on a queue of our own on GLFW's
  wl_display, which GLFW reads from as it waits, and are dispatched in
  yap_idle_check.
- X11: the MIT-SCREEN-SAVER extension (libXss), asked how long since
  the last input.

Neither library is linked at build time: each is loaded with dlopen(),
so a desktop without one only loses this, and the client goes on
counting input in its own window. The interfaces of the Wayland protocol
are written out here rather than generated, so building needs neither
wayland-scanner nor any headers.

Everything runs on the thread that runs GLFW.
*/
#include <dlfcn.h>
#include <stddef.h>
#include <stdint.h>

#include "yap_idle.h"

/* libwayland-client, as much of it as is used. */
struct wl_proxy;
struct wl_display;
struct wl_event_queue;
struct wl_message {
	const char *name;
	const char *signature;
	const struct wl_interface **types;
};
struct wl_interface {
	const char *name;
	int version;
	int method_count;
	const struct wl_message *methods;
	int event_count;
	const struct wl_message *events;
};

#define WL_MARSHAL_FLAG_DESTROY (1 << 0)
#define WL_DISPLAY_GET_REGISTRY 1
#define WL_REGISTRY_BIND 0

static struct {
	void *lib;
	struct wl_event_queue *(*create_queue)(struct wl_display *);
	void (*queue_destroy)(struct wl_event_queue *);
	void *(*create_wrapper)(void *);
	void (*wrapper_destroy)(void *);
	void (*set_queue)(struct wl_proxy *, struct wl_event_queue *);
	struct wl_proxy *(*marshal_flags)(struct wl_proxy *, uint32_t, const struct wl_interface *, uint32_t, uint32_t, ...);
	int (*add_listener)(struct wl_proxy *, void (**)(void), void *);
	void (*proxy_destroy)(struct wl_proxy *);
	uint32_t (*get_version)(struct wl_proxy *);
	int (*roundtrip_queue)(struct wl_display *, struct wl_event_queue *);
	int (*dispatch_queue_pending)(struct wl_display *, struct wl_event_queue *);
	const struct wl_interface *registry_interface;
	const struct wl_interface *seat_interface;
} wl;

/* ext-idle-notify-v1. */
static const struct wl_interface *no_types[3];
static const struct wl_interface *get_notification_types[3]; /* filled in by wl_load */
static const struct wl_message notifier_requests[] = {
	{"destroy", "", no_types},
	{"get_idle_notification", "nuo", get_notification_types},
};
static const struct wl_interface notifier_interface = {
	"ext_idle_notifier_v1", 1, 2, notifier_requests, 0, NULL,
};
static const struct wl_message notification_requests[] = {
	{"destroy", "", no_types},
};
static const struct wl_message notification_events[] = {
	{"idled", "", no_types},
	{"resumed", "", no_types},
};
static const struct wl_interface notification_interface = {
	"ext_idle_notification_v1", 1, 1, notification_requests, 2, notification_events,
};

static struct {
	struct wl_display *display;
	struct wl_event_queue *queue;
	struct wl_proxy *registry;
	struct wl_proxy *seat;
	struct wl_proxy *notifier;
	struct wl_proxy *notification;
	int idle;
} way;

/* libXss, and XDefaultRootWindow from libX11. */
typedef struct {
	unsigned long window;
	int state;
	int kind;
	unsigned long til_or_since;
	unsigned long idle; /* ms since the last input */
	unsigned long event_mask;
} Xss_Info;

static struct {
	void *xss;
	void *x11;
	void *display;
	unsigned long root;
	int (*query_info)(void *, unsigned long, Xss_Info *);
} xs;

static unsigned threshold_ms;

#define LOAD(lib, field, name) \
	if (!(*(void **)&(field) = dlsym((lib), (name)))) return 0

static int wl_load(void) {
	wl.lib = dlopen("libwayland-client.so.0", RTLD_LAZY | RTLD_LOCAL);
	if (!wl.lib) return 0;
	LOAD(wl.lib, wl.create_queue, "wl_display_create_queue");
	LOAD(wl.lib, wl.queue_destroy, "wl_event_queue_destroy");
	LOAD(wl.lib, wl.create_wrapper, "wl_proxy_create_wrapper");
	LOAD(wl.lib, wl.wrapper_destroy, "wl_proxy_wrapper_destroy");
	LOAD(wl.lib, wl.set_queue, "wl_proxy_set_queue");
	LOAD(wl.lib, wl.marshal_flags, "wl_proxy_marshal_flags");
	LOAD(wl.lib, wl.add_listener, "wl_proxy_add_listener");
	LOAD(wl.lib, wl.proxy_destroy, "wl_proxy_destroy");
	LOAD(wl.lib, wl.get_version, "wl_proxy_get_version");
	LOAD(wl.lib, wl.roundtrip_queue, "wl_display_roundtrip_queue");
	LOAD(wl.lib, wl.dispatch_queue_pending, "wl_display_dispatch_queue_pending");
	LOAD(wl.lib, wl.registry_interface, "wl_registry_interface");
	LOAD(wl.lib, wl.seat_interface, "wl_seat_interface");
	get_notification_types[0] = &notification_interface;
	get_notification_types[2] = wl.seat_interface;
	return 1;
}

static int str_eq(const char *a, const char *b) {
	while (*a && *a == *b) a++, b++;
	return *a == *b;
}

static struct wl_proxy *bind_global(uint32_t name, const struct wl_interface *iface) {
	return wl.marshal_flags(way.registry, WL_REGISTRY_BIND, iface, 1, 0, name, iface->name, 1, NULL);
}

static void on_global(void *data, struct wl_proxy *registry, uint32_t name, const char *iface, uint32_t version) {
	(void)data, (void)registry, (void)version;
	/* The first seat is the one the window's input comes from on any
	   desktop with one person at it. */
	if (!way.seat && str_eq(iface, "wl_seat")) {
		way.seat = bind_global(name, wl.seat_interface);
	} else if (!way.notifier && str_eq(iface, notifier_interface.name)) {
		way.notifier = bind_global(name, &notifier_interface);
	}
}

static void on_global_remove(void *data, struct wl_proxy *registry, uint32_t name) {
	(void)data, (void)registry, (void)name;
}

static void (*registry_listener[])(void) = {
	(void (*)(void))on_global,
	(void (*)(void))on_global_remove,
};

static void on_idled(void *data, struct wl_proxy *n) {
	(void)data, (void)n;
	way.idle = 1;
}

static void on_resumed(void *data, struct wl_proxy *n) {
	(void)data, (void)n;
	way.idle = 0;
}

static void (*notification_listener[])(void) = {
	(void (*)(void))on_idled,
	(void (*)(void))on_resumed,
};

static void wl_close(void) {
	if (way.notification) wl.marshal_flags(way.notification, 0, NULL, 1, WL_MARSHAL_FLAG_DESTROY);
	if (way.notifier) wl.marshal_flags(way.notifier, 0, NULL, 1, WL_MARSHAL_FLAG_DESTROY);
	if (way.seat) wl.proxy_destroy(way.seat);
	if (way.registry) wl.proxy_destroy(way.registry);
	if (way.queue) wl.queue_destroy(way.queue);
	way = (__typeof__(way)){0};
}

static int wl_open(void *display) {
	if (!wl.lib && !wl_load()) return 0;
	way.display = display;
	way.queue = wl.create_queue(way.display);
	if (!way.queue) return 0;
	/* The registry is made through a wrapper of the display, so that it
	   and everything bound through it use our queue, not GLFW's. */
	void *wrapper = wl.create_wrapper(display);
	if (!wrapper) {
		wl_close();
		return 0;
	}
	wl.set_queue(wrapper, way.queue);
	way.registry = wl.marshal_flags(wrapper, WL_DISPLAY_GET_REGISTRY, wl.registry_interface,
		wl.get_version(wrapper), 0, NULL);
	wl.wrapper_destroy(wrapper);
	if (!way.registry) {
		wl_close();
		return 0;
	}
	wl.add_listener(way.registry, registry_listener, NULL);
	wl.roundtrip_queue(way.display, way.queue);
	if (!way.seat || !way.notifier) {
		wl_close();
		return 0;
	}
	way.notification = wl.marshal_flags(way.notifier, 1, &notification_interface, 1, 0, NULL,
		threshold_ms, way.seat);
	if (!way.notification) {
		wl_close();
		return 0;
	}
	wl.add_listener(way.notification, notification_listener, NULL);
	wl.roundtrip_queue(way.display, way.queue);
	return 1;
}

static void x11_close(void) {
	if (xs.xss) dlclose(xs.xss);
	if (xs.x11) dlclose(xs.x11);
	xs = (__typeof__(xs)){0};
}

static int x11_open(void *display) {
	unsigned long (*default_root)(void *);
	int (*query_extension)(void *, int *, int *);
	int event_base, error_base;
	xs.x11 = dlopen("libX11.so.6", RTLD_LAZY | RTLD_LOCAL);
	xs.xss = dlopen("libXss.so.1", RTLD_LAZY | RTLD_LOCAL);
	if (!xs.x11 || !xs.xss ||
	    !(*(void **)&default_root = dlsym(xs.x11, "XDefaultRootWindow")) ||
	    !(*(void **)&query_extension = dlsym(xs.xss, "XScreenSaverQueryExtension")) ||
	    !(*(void **)&xs.query_info = dlsym(xs.xss, "XScreenSaverQueryInfo")) ||
	    !query_extension(display, &event_base, &error_base)) {
		x11_close();
		return 0;
	}
	xs.display = display;
	xs.root = default_root(display);
	return 1;
}

int yap_idle_open(void *wayland_display, void *x11_display, unsigned after_ms) {
	threshold_ms = after_ms;
	if (wayland_display) return wl_open(wayland_display) ? YAP_IDLE_WAYLAND : YAP_IDLE_NONE;
	if (x11_display) return x11_open(x11_display) ? YAP_IDLE_X11 : YAP_IDLE_NONE;
	return YAP_IDLE_NONE;
}

int yap_idle_check(void) {
	if (way.notification) {
		wl.dispatch_queue_pending(way.display, way.queue);
		return way.idle;
	}
	if (xs.display) {
		Xss_Info info = {0};
		if (!xs.query_info(xs.display, xs.root, &info)) return -1;
		return info.idle >= threshold_ms;
	}
	return -1;
}

void yap_idle_close(void) {
	if (way.queue) wl_close();
	if (xs.display) x11_close();
}
