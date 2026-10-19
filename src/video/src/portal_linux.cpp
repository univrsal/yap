/*
Capturing through xdg-desktop-portal's ScreenCast, which is how Wayland
desktops (and some X11 ones) let a program see the screen:

1. Over D-Bus (GLib's GDBus), CreateSession, SelectSources (a monitor or
   a window, with the cursor drawn in if wanted) and Start, each
   answered later by a Response signal. Start is when the desktop shows
   its picker, so it waits for the user, or for the share to be stopped
   (which closes the picker).
2. OpenPipeWireRemote hands over a PipeWire connection that can see the
   chosen stream and nothing else, and a PipeWire stream on it brings
   the pictures, on PipeWire's own thread. In shared memory, the newest
   is copied out for the share's thread. For a VA-API encoder, DMA-BUFs
   are offered first (linear ones, which VA-API always takes): the
   newest buffer is held rather than copied, and the share's thread
   imports it as a VA-API surface, has the GPU's video processor
   (vpp_linux.h) scale it into the encoder's NV12, and gives it back.
   If importing fails, the stream is renegotiated to shared memory.
3. The desktop can end it (its "stop sharing" button): the session's
   Closed signal or the stream going away say so.

Each share asks again; restore tokens, which would let the desktop skip
the picker the next time, are left for the UI phase. GLib and PipeWire
are loaded at run time (dl_linux.h).
*/
#include "capture_linux.h"
#include "dl_linux.h"

#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <utility>

#include <sys/stat.h>
#include <unistd.h>

#ifndef YV_NO_DMABUF
#include "vpp_linux.h"
#endif

#include "ffmpeg.h"

// Only types, so after ffmpeg.h.
extern "C" {
#include <libavutil/hwcontext_drm.h>
}

#include <gio/gio.h>
#include <gio/gunixfdlist.h>

#include <pipewire/pipewire.h>
#include <spa/buffer/meta.h>
#include <spa/param/video/format-utils.h>
#include <spa/pod/builder.h>

namespace yv {

namespace {

#define GLIB_FUNCS(X)                                                                              \
	X(g_free)                                                                                      \
	X(g_error_free)                                                                                \
	X(g_main_context_new)                                                                          \
	X(g_main_context_unref)                                                                        \
	X(g_main_context_iteration)                                                                    \
	X(g_main_context_push_thread_default)                                                          \
	X(g_main_context_pop_thread_default)                                                           \
	X(g_variant_new)                                                                               \
	X(g_variant_new_string)                                                                        \
	X(g_variant_new_uint32)                                                                        \
	X(g_variant_new_boolean)                                                                       \
	X(g_variant_builder_init)                                                                      \
	X(g_variant_builder_add)                                                                       \
	X(g_variant_builder_end)                                                                       \
	X(g_variant_get)                                                                               \
	X(g_variant_lookup)                                                                            \
	X(g_variant_lookup_value)                                                                      \
	X(g_variant_n_children)                                                                        \
	X(g_variant_get_child)                                                                         \
	X(g_variant_unref)

#define GOBJECT_FUNCS(X) X(g_object_unref)

#define GIO_FUNCS(X)                                                                               \
	X(g_bus_get_sync)                                                                              \
	X(g_dbus_connection_get_unique_name)                                                           \
	X(g_dbus_connection_call_sync)                                                                 \
	X(g_dbus_connection_call_with_unix_fd_list_sync)                                               \
	X(g_dbus_connection_signal_subscribe)                                                          \
	X(g_dbus_connection_signal_unsubscribe)                                                        \
	X(g_unix_fd_list_get)

#define PW_FUNCS(X)                                                                                \
	X(pw_init)                                                                                     \
	X(pw_thread_loop_new)                                                                          \
	X(pw_thread_loop_destroy)                                                                      \
	X(pw_thread_loop_start)                                                                        \
	X(pw_thread_loop_stop)                                                                         \
	X(pw_thread_loop_lock)                                                                         \
	X(pw_thread_loop_unlock)                                                                       \
	X(pw_thread_loop_get_loop)                                                                     \
	X(pw_context_new)                                                                              \
	X(pw_context_destroy)                                                                          \
	X(pw_context_connect_fd)                                                                       \
	X(pw_core_disconnect)                                                                          \
	X(pw_properties_new)                                                                           \
	X(pw_stream_new)                                                                               \
	X(pw_stream_add_listener)                                                                      \
	X(pw_stream_connect)                                                                           \
	X(pw_stream_disconnect)                                                                        \
	X(pw_stream_destroy)                                                                           \
	X(pw_stream_dequeue_buffer)                                                                    \
	X(pw_stream_queue_buffer)                                                                      \
	X(pw_stream_update_params)                                                                     \
	X(pw_stream_state_as_string)

struct Libs {
	GLIB_FUNCS(YV_DL_POINTER)
	GOBJECT_FUNCS(YV_DL_POINTER)
	GIO_FUNCS(YV_DL_POINTER)
	PW_FUNCS(YV_DL_POINTER)
	bool glib = false, pipewire = false;
};

/*
Called as (g.g_free)(p), never g.g_free(p): newer GLib makes some of its
functions macros too (g_free in 2.86), which would expand inside the
latter.
*/
const Libs &libs() {
	static Libs l;
	static std::once_flag once;
	std::call_once(once, [] {
		Libs &api = l;
		Dl_Lib glib, gobject, gio, pw;
		{
			Dl_Lib &lib = glib;
			l.glib = lib.open({"libglib-2.0.so.0"}) && GLIB_FUNCS(YV_DL_LOAD) true;
		}
		{
			Dl_Lib &lib = gobject;
			l.glib = l.glib && lib.open({"libgobject-2.0.so.0"}) && GOBJECT_FUNCS(YV_DL_LOAD) true;
		}
		{
			Dl_Lib &lib = gio;
			l.glib = l.glib && lib.open({"libgio-2.0.so.0"}) && GIO_FUNCS(YV_DL_LOAD) true;
		}
		{
			Dl_Lib &lib = pw;
			l.pipewire = lib.open({"libpipewire-0.3.so.0"}) && PW_FUNCS(YV_DL_LOAD) true;
		}
		if (!l.glib) {
			log(YV_LOG_INFO, "no GLib's GIO, so no portal");
		}
		if (!l.pipewire) {
			log(YV_LOG_INFO, "no libpipewire, so no portal");
		}
		if (l.pipewire) {
			l.pw_init(nullptr, nullptr);
		}
	});
	return l;
}

// G_VARIANT_TYPE without its check, which would be a call into GLib.
const GVariantType *vtype(const char *s) {
	return reinterpret_cast<const GVariantType *>(s);
}

const char PORTAL[] = "org.freedesktop.portal.Desktop";
const char PORTAL_PATH[] = "/org/freedesktop/portal/desktop";
const char SCREENCAST[] = "org.freedesktop.portal.ScreenCast";

// What the source types and cursor modes mean to the portal.
constexpr uint32_t SOURCE_MONITOR = 1, SOURCE_WINDOW = 2;
constexpr uint32_t CURSOR_HIDDEN = 1, CURSOR_EMBEDDED = 2;

// Whether there's a session bus to talk to, without GLib trying to
// start one (it would, given an X display).
bool session_bus_there() {
	const char *addr = getenv("DBUS_SESSION_BUS_ADDRESS");
	if (addr && *addr) {
		return true;
	}
	const char *run = getenv("XDG_RUNTIME_DIR");
	struct stat st;
	return run && stat((std::string(run) + "/bus").c_str(), &st) == 0;
}

GDBusConnection *session_bus() {
	const Libs &g = libs();
	if (!g.glib || !session_bus_there()) {
		return nullptr;
	}
	GError *err = nullptr;
	GDBusConnection *bus = (g.g_bus_get_sync)(G_BUS_TYPE_SESSION, nullptr, &err);
	if (!bus) {
		log(YV_LOG_INFO, "no session bus: %s", err ? err->message : "?");
		if (err) {
			(g.g_error_free)(err);
		}
	}
	return bus;
}

// A ScreenCast property, as a uint32; 0 if it can't be read.
uint32_t screencast_property(GDBusConnection *bus, const char *name) {
	const Libs &g = libs();
	GError *err = nullptr;
	GVariant *ret = (g.g_dbus_connection_call_sync)(
		bus, PORTAL, PORTAL_PATH, "org.freedesktop.DBus.Properties", "Get",
		(g.g_variant_new)("(ss)", SCREENCAST, name), vtype("(v)"), G_DBUS_CALL_FLAGS_NONE,
		2000, nullptr, &err);
	if (!ret) {
		log(YV_LOG_DEBUG, "portal: no %s: %s", name, err ? err->message : "?");
		if (err) {
			(g.g_error_free)(err);
		}
		return 0;
	}
	GVariant *v = nullptr;
	(g.g_variant_get)(ret, "(v)", &v);
	uint32_t out = 0;
	(g.g_variant_get)(v, "u", &out);
	(g.g_variant_unref)(v);
	(g.g_variant_unref)(ret);
	return out;
}

struct Response {
	bool done = false;
	uint32_t code = 2;
	GVariant *results = nullptr;
};

void on_response(GDBusConnection *, const gchar *, const gchar *, const gchar *, const gchar *,
                 GVariant *params, gpointer user) {
	auto *r = static_cast<Response *>(user);
	if (r->done) {
		return;
	}
	(libs().g_variant_get)(params, "(u@a{sv})", &r->code, &r->results);
	r->done = true;
}

void on_closed(GDBusConnection *, const gchar *, const gchar *, const gchar *, const gchar *,
               GVariant *, gpointer user) {
	static_cast<std::atomic<bool> *>(user)->store(true);
}

/*
Portal_Session is the D-Bus side: the requests that set the session up,
and closing it.
*/
class Portal_Session {
public:
	std::atomic<bool> closed{false};
	bool cancelled = false; // the user said no in the picker

	~Portal_Session() {
		const Libs &g = libs();
		if (closed_sub_) {
			(g.g_dbus_connection_signal_unsubscribe)(bus_, closed_sub_);
		}
		if (!session_.empty() && !closed.load()) {
			call(session_.c_str(), "org.freedesktop.portal.Session", "Close", nullptr);
		}
		if (ctx_) {
			(g.g_main_context_unref)(ctx_);
		}
		if (bus_) {
			(g.g_object_unref)(bus_);
		}
	}

	/*
	start asks for a source and waits for the user's choice. It gives
	the PipeWire node to connect to and a connection that can reach it
	(a file descriptor, to be closed), or says why not.
	*/
	bool start(const yv_share_config &config, const std::atomic<bool> &stop, uint32_t &node,
	           int &fd, std::string &error) {
		const Libs &g = libs();
		bus_ = session_bus();
		if (!bus_) {
			error = "can't reach the desktop's portal";
			return false;
		}
		// "Request handles" are made from our name on the bus: ":1.42"
		// becomes "1_42".
		const char *unique = (g.g_dbus_connection_get_unique_name)(bus_);
		for (const char *p = unique && *unique == ':' ? unique + 1 : unique; p && *p; p++) {
			sender_ += *p == '.' ? '_' : *p;
		}
		ctx_ = (g.g_main_context_new)();

		uint32_t types = screencast_property(bus_, "AvailableSourceTypes");
		uint32_t cursors = screencast_property(bus_, "AvailableCursorModes");
		uint32_t want_types = SOURCE_MONITOR | SOURCE_WINDOW;
		if (types & want_types) {
			want_types &= types;
		}

		// CreateSession
		GVariant *results = nullptr;
		GVariantBuilder opts;
		(g.g_variant_builder_init)(&opts, G_VARIANT_TYPE_VARDICT);
		std::string session_token = token();
		(g.g_variant_builder_add)(&opts, "{sv}", "session_handle_token",
		                        (g.g_variant_new_string)(session_token.c_str()));
		if (!request("CreateSession", "", opts, stop, results, error)) {
			return false;
		}
		gchar *handle = nullptr;
		(g.g_variant_lookup)(results, "session_handle", "s", &handle);
		(g.g_variant_unref)(results);
		if (!handle) {
			error = "the portal made no session";
			return false;
		}
		session_ = handle;
		(g.g_free)(handle);
		GMainContext *ctx = ctx_;
		(g.g_main_context_push_thread_default)(ctx);
		closed_sub_ = (g.g_dbus_connection_signal_subscribe)(
			bus_, nullptr, "org.freedesktop.portal.Session", "Closed", session_.c_str(), nullptr,
			G_DBUS_SIGNAL_FLAGS_NONE, on_closed, &closed, nullptr);
		(g.g_main_context_pop_thread_default)(ctx);

		// SelectSources
		(g.g_variant_builder_init)(&opts, G_VARIANT_TYPE_VARDICT);
		(g.g_variant_builder_add)(&opts, "{sv}", "types", (g.g_variant_new_uint32)(want_types));
		(g.g_variant_builder_add)(&opts, "{sv}", "multiple", (g.g_variant_new_boolean)(FALSE));
		uint32_t cursor = config.cursor ? CURSOR_EMBEDDED : CURSOR_HIDDEN;
		if (cursors & cursor) {
			(g.g_variant_builder_add)(&opts, "{sv}", "cursor_mode", (g.g_variant_new_uint32)(cursor));
		}
		if (!request("SelectSources", session_, opts, stop, results, error)) {
			return false;
		}
		(g.g_variant_unref)(results);

		// Start, which shows the picker.
		(g.g_variant_builder_init)(&opts, G_VARIANT_TYPE_VARDICT);
		if (!request("Start", session_, opts, stop, results, error)) {
			return false;
		}
		GVariant *streams = (g.g_variant_lookup_value)(results, "streams", vtype("a(ua{sv})"));
		(g.g_variant_unref)(results);
		if (!streams || (g.g_variant_n_children)(streams) == 0) {
			if (streams) {
				(g.g_variant_unref)(streams);
			}
			error = "nothing was chosen to share";
			return false;
		}
		GVariant *props = nullptr;
		(g.g_variant_get_child)(streams, 0, "(u@a{sv})", &node, &props);
		(g.g_variant_unref)(props);
		(g.g_variant_unref)(streams);

		// OpenPipeWireRemote
		(g.g_variant_builder_init)(&opts, G_VARIANT_TYPE_VARDICT);
		GUnixFDList *fds = nullptr;
		GError *err = nullptr;
		GVariant *ret = (g.g_dbus_connection_call_with_unix_fd_list_sync)(
			bus_, PORTAL, PORTAL_PATH, SCREENCAST, "OpenPipeWireRemote",
			(g.g_variant_new)("(o@a{sv})", session_.c_str(), (g.g_variant_builder_end)(&opts)),
			vtype("(h)"), G_DBUS_CALL_FLAGS_NONE, -1, nullptr, &fds, nullptr, &err);
		if (!ret) {
			error = std::string("the portal won't hand over PipeWire: ") +
			        (err ? err->message : "?");
			if (err) {
				(g.g_error_free)(err);
			}
			return false;
		}
		int32_t index = 0;
		(g.g_variant_get)(ret, "(h)", &index);
		(g.g_variant_unref)(ret);
		fd = fds ? (g.g_unix_fd_list_get)(fds, index, nullptr) : -1;
		if (fds) {
			(g.g_object_unref)(fds);
		}
		if (fd < 0) {
			error = "the portal handed over no PipeWire connection";
			return false;
		}
		return true;
	}

	// poll lets D-Bus signals in (the session being closed).
	void poll() {
		if (ctx_) {
			while ((libs().g_main_context_iteration)(ctx_, FALSE)) {
			}
		}
	}

private:
	GDBusConnection *bus_ = nullptr;
	GMainContext *ctx_ = nullptr;
	std::string sender_;
	std::string session_;
	unsigned closed_sub_ = 0;
	int tokens_ = 0;

	std::string token() {
		return "yap" + std::to_string(getpid()) + "_" + std::to_string(++tokens_);
	}

	GVariant *call(const char *path, const char *iface, const char *method, GVariant *params) {
		const Libs &g = libs();
		GError *err = nullptr;
		GVariant *ret = (g.g_dbus_connection_call_sync)(bus_, PORTAL, path, iface, method, params,
		                                              nullptr, G_DBUS_CALL_FLAGS_NONE, -1, nullptr,
		                                              &err);
		if (!ret) {
			log(YV_LOG_WARN, "portal: %s: %s", method, err ? err->message : "?");
			if (err) {
				(g.g_error_free)(err);
			}
		}
		return ret;
	}

	/*
	request calls a ScreenCast method that answers with a Response
	signal (CreateSession, SelectSources, Start), the session first
	unless `session` is empty, `opts` last, and waits for the answer.
	*/
	bool request(const char *method, const std::string &session, GVariantBuilder &opts,
	             const std::atomic<bool> &stop, GVariant *&results, std::string &error) {
		const Libs &g = libs();
		std::string tok = token();
		(g.g_variant_builder_add)(&opts, "{sv}", "handle_token", (g.g_variant_new_string)(tok.c_str()));
		std::string path = std::string(PORTAL_PATH) + "/request/" + sender_ + "/" + tok;
		// Listening before asking, so the answer can't come first.
		Response r;
		(g.g_main_context_push_thread_default)(ctx_);
		unsigned sub = (g.g_dbus_connection_signal_subscribe)(
			bus_, nullptr, "org.freedesktop.portal.Request", "Response", path.c_str(), nullptr,
			G_DBUS_SIGNAL_FLAGS_NONE, on_response, &r, nullptr);
		(g.g_main_context_pop_thread_default)(ctx_);

		GVariant *o = (g.g_variant_builder_end)(&opts);
		GVariant *params;
		if (session.empty()) {
			params = (g.g_variant_new)("(@a{sv})", o);
		} else if (strcmp(method, "Start") == 0) {
			params = (g.g_variant_new)("(os@a{sv})", session.c_str(), "", o);
		} else {
			params = (g.g_variant_new)("(o@a{sv})", session.c_str(), o);
		}
		GVariant *ret = call(PORTAL_PATH, SCREENCAST, method, params);
		if (!ret) {
			(g.g_dbus_connection_signal_unsubscribe)(bus_, sub);
			error = std::string("the portal refused ") + method;
			return false;
		}
		(g.g_variant_unref)(ret);
		while (!r.done) {
			if (stop.load()) {
				// Takes the picker down, if it's up.
				GVariant *c = call(path.c_str(), "org.freedesktop.portal.Request", "Close", nullptr);
				if (c) {
					(g.g_variant_unref)(c);
				}
				break;
			}
			if (!(g.g_main_context_iteration)(ctx_, FALSE)) {
				std::this_thread::sleep_for(std::chrono::milliseconds(10));
			}
		}
		(g.g_dbus_connection_signal_unsubscribe)(bus_, sub);
		if (!r.done) {
			error = "stopped before anything was chosen";
			return false;
		}
		if (r.code != 0) {
			if (r.results) {
				(g.g_variant_unref)(r.results);
			}
			cancelled = r.code == 1;
			error = r.code == 1 ? "sharing was cancelled" : std::string("the portal's ") + method +
			                                                     " failed";
			return false;
		}
		results = r.results;
		return true;
	}
};

// DRM's name for each of those formats, for importing a DMA-BUF.
uint32_t drm_format(AVPixelFormat f) {
	auto fourcc = [](char a, char b, char c, char d) {
		return static_cast<uint32_t>(a) | static_cast<uint32_t>(b) << 8 |
		       static_cast<uint32_t>(c) << 16 | static_cast<uint32_t>(d) << 24;
	};
	switch (f) {
	case AV_PIX_FMT_BGR0:
		return fourcc('X', 'R', '2', '4');
	case AV_PIX_FMT_BGRA:
		return fourcc('A', 'R', '2', '4');
	case AV_PIX_FMT_RGB0:
		return fourcc('X', 'B', '2', '4');
	case AV_PIX_FMT_RGBA:
		return fourcc('A', 'B', '2', '4');
	default:
		return 0;
	}
}

// The only layout offered: plain rows, which VA-API always imports.
constexpr uint64_t DRM_FORMAT_MOD_LINEAR = 0;

// A DMA-BUF the compositor gave us, held until it's given back.
struct Dmabuf_Frame {
	pw_buffer *buf = nullptr;
	int fd = -1;
	uint32_t offset = 0, stride = 0;
	uint64_t modifier = 0;
	AVPixelFormat format = AV_PIX_FMT_NONE;
	int width = 0, height = 0; // the buffer
	int x = 0, y = 0, w = 0, h = 0; // what's in it (a window's crop)
};

/*
build_format makes an EnumFormat: in memory, or as DMA-BUFs, whose
modifier is offered for the compositor to leave to us (`fixed` false) or
fixed.
*/
const spa_pod *build_format(spa_pod_builder *b, int fps, bool dmabuf, bool fixed) {
	spa_rectangle size_def{1920, 1080}, size_min{1, 1}, size_max{16384, 16384};
	spa_fraction rate{0, 1}, max_def{static_cast<uint32_t>(fps), 1}, max_min{0, 1},
		max_max{static_cast<uint32_t>(fps), 1};
	spa_pod_frame f;
	spa_pod_builder_push_object(b, &f, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat);
	// Whatever rate it changes at, at most `fps`.
	spa_pod_builder_add(
		b, SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video), SPA_FORMAT_mediaSubtype,
		SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw), SPA_FORMAT_VIDEO_format,
		SPA_POD_CHOICE_ENUM_Id(5, SPA_VIDEO_FORMAT_BGRx, SPA_VIDEO_FORMAT_BGRx,
	                           SPA_VIDEO_FORMAT_BGRA, SPA_VIDEO_FORMAT_RGBx, SPA_VIDEO_FORMAT_RGBA),
		SPA_FORMAT_VIDEO_size, SPA_POD_CHOICE_RANGE_Rectangle(&size_def, &size_min, &size_max),
		SPA_FORMAT_VIDEO_framerate, SPA_POD_Fraction(&rate), SPA_FORMAT_VIDEO_maxFramerate,
		SPA_POD_CHOICE_RANGE_Fraction(&max_def, &max_min, &max_max), 0);
	if (dmabuf) {
		uint32_t flags = SPA_POD_PROP_FLAG_MANDATORY;
		if (!fixed) {
			flags |= SPA_POD_PROP_FLAG_DONT_FIXATE;
		}
		spa_pod_builder_prop(b, SPA_FORMAT_VIDEO_modifier, flags);
		if (fixed) {
			spa_pod_builder_long(b, static_cast<int64_t>(DRM_FORMAT_MOD_LINEAR));
		} else {
			spa_pod_frame c;
			spa_pod_builder_push_choice(b, &c, SPA_CHOICE_Enum, 0);
			spa_pod_builder_long(b, static_cast<int64_t>(DRM_FORMAT_MOD_LINEAR)); // the default
			spa_pod_builder_long(b, static_cast<int64_t>(DRM_FORMAT_MOD_LINEAR));
			spa_pod_builder_pop(b, &c);
		}
	}
	return static_cast<const spa_pod *>(spa_pod_builder_pop(b, &f));
}

AVPixelFormat av_format(uint32_t spa) {
	switch (spa) {
	case SPA_VIDEO_FORMAT_BGRx:
		return AV_PIX_FMT_BGR0;
	case SPA_VIDEO_FORMAT_BGRA:
		return AV_PIX_FMT_BGRA;
	case SPA_VIDEO_FORMAT_RGBx:
		return AV_PIX_FMT_RGB0;
	case SPA_VIDEO_FORMAT_RGBA:
		return AV_PIX_FMT_RGBA;
	default:
		return AV_PIX_FMT_NONE;
	}
}

class Portal_Pipeline : public Memory_Pipeline {
public:
	~Portal_Pipeline() override {
		const Libs &g = libs();
		// The surface goes before the device does (Memory_Pipeline's).
		av_frame_free(&mapped_);
		av_buffer_unref(&rgb_frames_);
		if (loop_) {
			g.pw_thread_loop_lock(loop_);
			if (stream_) {
				g.pw_stream_disconnect(stream_);
				g.pw_stream_destroy(stream_);
			}
			if (core_) {
				g.pw_core_disconnect(core_);
			}
			g.pw_thread_loop_unlock(loop_);
			g.pw_thread_loop_stop(loop_);
		}
		if (context_) {
			g.pw_context_destroy(context_);
		}
		if (loop_) {
			g.pw_thread_loop_destroy(loop_);
		}
	}

	bool open(const yv_share_config &config, const char *encoder, const std::atomic<bool> &stop,
	          std::string &error) override {
		uint32_t node = 0;
		int fd = -1;
		if (!portal_.start(config, stop, node, fd, error)) {
			return false;
		}
		open_device(encoder);
#ifndef YV_NO_DMABUF
		want_dmabuf_ = device() && Vpp::available() && !software_only() &&
		               !getenv("YAP_VIDEO_NO_DMABUF");
#endif
		fps_ = config.fps;
		if (!connect(fd, node)) {
			error = "can't connect to what the portal shares";
			return false;
		}
		log(YV_LOG_INFO, "share: capturing PipeWire node %u from the portal%s", node,
		    want_dmabuf_ ? ", DMA-BUFs if it has them" : "");
		return true;
	}

	int width() override {
		return mapped_ ? held_.w : Memory_Pipeline::width();
	}

	int height() override {
		return mapped_ ? held_.h : Memory_Pipeline::height();
	}

	bool convert(AVFrame *out, AVBufferRef *frames, int w, int h) override {
		if (!mapped_) {
			return Memory_Pipeline::convert(out, frames, w, h);
		}
#ifndef YV_NO_DMABUF
		// Only offered for a VA-API encoder, which takes these.
		if (frames && av_hwframe_get_buffer(frames, out, 0) >= 0) {
			auto in = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(mapped_->data[3]));
			auto to = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(out->data[3]));
			if (vpp_.run(device(), in, held_.x, held_.y, held_.w, held_.h, to, w, h)) {
				return true;
			}
		}
		av_frame_unref(out);
#endif
		return false;
	}

	bool cancelled() override {
		return portal_.cancelled;
	}

	bool wait(int ms, bool &closed) override {
		portal_.poll();
		std::unique_lock<std::mutex> lock(mutex_);
		cv_.wait_for(lock, std::chrono::milliseconds(ms), [this] { return fresh_ || ended_; });
		closed = ended_ || portal_.closed.load();
		if (!fresh_) {
			return false;
		}
		fresh_ = false;
		if (pending_buf_.buf) {
			Dmabuf_Frame f = pending_buf_;
			pending_buf_ = {};
			lock.unlock();
			return import(f);
		}
		std::swap(latest_, pending_);
		lock.unlock();
		release_held(); // in memory again: what was held is done with
		return true;
	}

private:
	Portal_Session portal_;
	pw_thread_loop *loop_ = nullptr;
	pw_context *context_ = nullptr;
	pw_core *core_ = nullptr;
	pw_stream *stream_ = nullptr;
	spa_hook listener_{};
	pw_stream_events events_{};

	// Set before connecting.
	bool want_dmabuf_ = false; // offer DMA-BUFs (a VA-API encoder)
	int fps_ = 60;

	// PipeWire's thread's.
	AVPixelFormat format_ = AV_PIX_FMT_NONE;
	int width_ = 0, height_ = 0;
	bool streaming_ = false;
	bool dmabuf_ = false; // the format agreed on is in DMA-BUFs
	uint64_t modifier_ = 0;
	Image incoming_;

	// Shared, under mutex_.
	std::mutex mutex_;
	std::condition_variable cv_;
	Image pending_;
	Dmabuf_Frame pending_buf_; // the newest DMA-BUF, not yet taken
	bool fresh_ = false;
	bool ended_ = false;
	// held_.buf too: PipeWire may take it away (on_remove_buffer).
	Dmabuf_Frame held_;
	// The share's thread found DMA-BUFs don't import; read on PipeWire's.
	std::atomic<bool> dmabuf_off_{false};

	// The share's thread's: held_ as a VA-API surface.
	AVFrame *mapped_ = nullptr;
	AVBufferRef *rgb_frames_ = nullptr;
#ifndef YV_NO_DMABUF
	Vpp vpp_;
#endif

	// offer sends the formats we take, best first. On PipeWire's thread,
	// or with its loop locked.
	void offer(bool fixed) {
		uint8_t buf[2048];
		spa_pod_builder b;
		spa_pod_builder_init(&b, buf, sizeof(buf));
		const spa_pod *params[2];
		uint32_t n = 0;
		if (want_dmabuf_ && !dmabuf_off_.load()) {
			params[n++] = build_format(&b, fps_, true, fixed);
		}
		params[n++] = build_format(&b, fps_, false, false);
		libs().pw_stream_update_params(stream_, params, n);
	}

	/*
	import takes `f` from the compositor as a VA-API surface, letting go
	of what it held before. If VA-API won't have it, it asks for shared
	memory from now on.
	*/
	bool import(const Dmabuf_Frame &f) {
		release_held();
		{
			std::lock_guard<std::mutex> lock(mutex_);
			held_ = f;
		}
		AVBufferRef *device = this->device();
		uint32_t fourcc = drm_format(f.format);
		bool ok = device && fourcc != 0;
		if (ok && (!rgb_frames_ || frames_size(rgb_frames_) != std::pair{f.width, f.height} ||
		           reinterpret_cast<AVHWFramesContext *>(rgb_frames_->data)->sw_format != f.format)) {
			av_buffer_unref(&rgb_frames_);
			rgb_frames_ = av_hwframe_ctx_alloc(device);
			if (rgb_frames_) {
				auto *fc = reinterpret_cast<AVHWFramesContext *>(rgb_frames_->data);
				fc->format = AV_PIX_FMT_VAAPI;
				fc->sw_format = f.format;
				fc->width = f.width;
				fc->height = f.height;
				if (av_hwframe_ctx_init(rgb_frames_) < 0) {
					av_buffer_unref(&rgb_frames_);
				}
			}
			ok = rgb_frames_ != nullptr;
		}
		if (ok) {
			auto *desc = static_cast<AVDRMFrameDescriptor *>(av_mallocz(sizeof(AVDRMFrameDescriptor)));
			desc->nb_objects = 1;
			desc->objects[0].fd = f.fd;
			off_t size = lseek(f.fd, 0, SEEK_END);
			desc->objects[0].size = size > 0 ? static_cast<size_t>(size) : 0;
			desc->objects[0].format_modifier = f.modifier;
			desc->nb_layers = 1;
			desc->layers[0].format = fourcc;
			desc->layers[0].nb_planes = 1;
			desc->layers[0].planes[0] = {0, static_cast<ptrdiff_t>(f.offset),
			                             static_cast<ptrdiff_t>(f.stride)};
			AVFrame *src = av_frame_alloc();
			src->format = AV_PIX_FMT_DRM_PRIME;
			src->width = f.width;
			src->height = f.height;
			src->data[0] = reinterpret_cast<uint8_t *>(desc);
			src->buf[0] = av_buffer_create(reinterpret_cast<uint8_t *>(desc), sizeof(*desc),
			                               av_buffer_default_free, nullptr, 0);
			mapped_ = av_frame_alloc();
			mapped_->format = AV_PIX_FMT_VAAPI;
			mapped_->hw_frames_ctx = av_buffer_ref(rgb_frames_);
			ok = src->buf[0] && av_hwframe_map(mapped_, src, AV_HWFRAME_MAP_READ) >= 0;
			av_frame_free(&src);
			if (!ok) {
				av_frame_free(&mapped_);
			}
		}
		if (!ok) {
			log(YV_LOG_INFO, "share: VA-API won't import the compositor's DMA-BUFs; asking for "
			                 "shared memory instead");
			release_held();
			dmabuf_off_.store(true);
			const Libs &g = libs();
			g.pw_thread_loop_lock(loop_);
			offer(false);
			g.pw_thread_loop_unlock(loop_);
		}
		return ok;
	}

	static std::pair<int, int> frames_size(AVBufferRef *frames) {
		auto *fc = reinterpret_cast<AVHWFramesContext *>(frames->data);
		return {fc->width, fc->height};
	}

	// release_held gives the held DMA-BUF back, once nothing uses it.
	void release_held() {
		av_frame_free(&mapped_);
		pw_buffer *buf = nullptr;
		{
			std::lock_guard<std::mutex> lock(mutex_);
			buf = held_.buf;
			held_ = {};
		}
		if (buf) {
			const Libs &g = libs();
			g.pw_thread_loop_lock(loop_);
			g.pw_stream_queue_buffer(stream_, buf);
			g.pw_thread_loop_unlock(loop_);
		}
	}

	bool connect(int fd, uint32_t node) {
		const Libs &g = libs();
		loop_ = g.pw_thread_loop_new("yap-capture", nullptr);
		if (!loop_) {
			close(fd);
			return false;
		}
		context_ = g.pw_context_new(g.pw_thread_loop_get_loop(loop_), nullptr, 0);
		if (!context_ || g.pw_thread_loop_start(loop_) < 0) {
			close(fd);
			return false;
		}
		g.pw_thread_loop_lock(loop_);
		core_ = g.pw_context_connect_fd(context_, fd, nullptr, 0); // takes the fd
		if (core_) {
			stream_ = g.pw_stream_new(core_, "yap screen share",
			                          g.pw_properties_new(PW_KEY_MEDIA_TYPE, "Video",
			                                              PW_KEY_MEDIA_CATEGORY, "Capture",
			                                              PW_KEY_MEDIA_ROLE, "Screen", nullptr));
		}
		bool ok = stream_ != nullptr;
		if (ok) {
			events_.version = PW_VERSION_STREAM_EVENTS;
			events_.state_changed = on_state;
			events_.param_changed = on_param;
			events_.process = on_process;
			events_.remove_buffer = on_remove_buffer;
			g.pw_stream_add_listener(stream_, &listener_, &events_, this);

			uint8_t buf[2048];
			spa_pod_builder b;
			spa_pod_builder_init(&b, buf, sizeof(buf));
			const spa_pod *params[2];
			uint32_t n = 0;
			if (want_dmabuf_) {
				params[n++] = build_format(&b, fps_, true, false);
			}
			params[n++] = build_format(&b, fps_, false, false);
			ok = g.pw_stream_connect(stream_, PW_DIRECTION_INPUT, node,
			                         static_cast<pw_stream_flags>(PW_STREAM_FLAG_AUTOCONNECT |
			                                                      PW_STREAM_FLAG_MAP_BUFFERS),
			                         params, n) == 0;
		}
		g.pw_thread_loop_unlock(loop_);
		return ok;
	}

	static void on_state(void *data, pw_stream_state, pw_stream_state state, const char *error) {
		auto *p = static_cast<Portal_Pipeline *>(data);
		log(state == PW_STREAM_STATE_ERROR ? YV_LOG_WARN : YV_LOG_DEBUG, "share: pipewire %s%s%s",
		    libs().pw_stream_state_as_string(state), error ? ": " : "", error ? error : "");
		if (state == PW_STREAM_STATE_STREAMING) {
			p->streaming_ = true;
		}
		if (state == PW_STREAM_STATE_ERROR ||
		    (state == PW_STREAM_STATE_UNCONNECTED && p->streaming_)) {
			std::lock_guard<std::mutex> lock(p->mutex_);
			p->ended_ = true;
			p->cv_.notify_one();
		}
	}

	static void on_param(void *data, uint32_t id, const spa_pod *param) {
		auto *p = static_cast<Portal_Pipeline *>(data);
		if (!param || id != SPA_PARAM_Format) {
			return;
		}
		uint32_t media_type = 0, media_subtype = 0;
		spa_video_info_raw raw{};
		if (spa_format_parse(param, &media_type, &media_subtype) < 0 ||
		    media_type != SPA_MEDIA_TYPE_video || media_subtype != SPA_MEDIA_SUBTYPE_raw ||
		    spa_format_video_raw_parse(param, &raw) < 0) {
			return;
		}
		const spa_pod_prop *modifier = spa_pod_find_prop(param, nullptr, SPA_FORMAT_VIDEO_modifier);
		if (modifier && (modifier->flags & SPA_POD_PROP_FLAG_DONT_FIXATE)) {
			// The compositor left the layout to us: the one we offer.
			p->offer(true);
			return;
		}
		p->format_ = av_format(raw.format);
		p->width_ = static_cast<int>(raw.size.width);
		p->height_ = static_cast<int>(raw.size.height);
		p->dmabuf_ = modifier != nullptr;
		p->modifier_ = raw.modifier;
		log(YV_LOG_INFO, "share: the portal sends %dx%d%s", p->width_, p->height_,
		    p->dmabuf_ ? " in DMA-BUFs" : "");

		// Buffers we can read (DMA-BUFs, or memory), and the metadata
		// saying which part of them holds a window.
		uint8_t buf[1024];
		spa_pod_builder b;
		spa_pod_builder_init(&b, buf, sizeof(buf));
		const spa_pod *params[3];
		params[0] = static_cast<const spa_pod *>(spa_pod_builder_add_object(
			&b, SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers, SPA_PARAM_BUFFERS_dataType,
			SPA_POD_CHOICE_FLAGS_Int(p->dmabuf_ ? (1 << SPA_DATA_DmaBuf)
		                                         : (1 << SPA_DATA_MemPtr) | (1 << SPA_DATA_MemFd))));
		params[1] = static_cast<const spa_pod *>(spa_pod_builder_add_object(
			&b, SPA_TYPE_OBJECT_ParamMeta, SPA_PARAM_Meta, SPA_PARAM_META_type,
			SPA_POD_Id(SPA_META_Header), SPA_PARAM_META_size,
			SPA_POD_Int(sizeof(struct spa_meta_header))));
		params[2] = static_cast<const spa_pod *>(spa_pod_builder_add_object(
			&b, SPA_TYPE_OBJECT_ParamMeta, SPA_PARAM_Meta, SPA_PARAM_META_type,
			SPA_POD_Id(SPA_META_VideoCrop), SPA_PARAM_META_size,
			SPA_POD_Int(sizeof(struct spa_meta_region))));
		libs().pw_stream_update_params(p->stream_, params, 3);
	}

	static void on_process(void *data) {
		auto *p = static_cast<Portal_Pipeline *>(data);
		const Libs &g = libs();
		// The newest buffer; older ones go straight back.
		pw_buffer *newest = nullptr;
		while (pw_buffer *b = g.pw_stream_dequeue_buffer(p->stream_)) {
			if (newest) {
				g.pw_stream_queue_buffer(p->stream_, newest);
			}
			newest = b;
		}
		if (!newest) {
			return;
		}
		if (p->dmabuf_) {
			p->hold(newest); // goes back once used (release_held)
			return;
		}
		p->take(newest->buffer);
		g.pw_stream_queue_buffer(p->stream_, newest);
	}

	// on_remove_buffer: PipeWire takes a buffer away (new buffers for a
	// new size), which mustn't be given back after.
	static void on_remove_buffer(void *data, pw_buffer *buffer) {
		auto *p = static_cast<Portal_Pipeline *>(data);
		std::lock_guard<std::mutex> lock(p->mutex_);
		if (p->pending_buf_.buf == buffer) {
			p->pending_buf_ = {};
		}
		if (p->held_.buf == buffer) {
			// Its surface is VA-API's own by now; only giving it back is off.
			p->held_.buf = nullptr;
		}
	}

	/*
	hold keeps a DMA-BUF for the share's thread (wait), giving back the
	one it had kept before if that wasn't taken. On PipeWire's thread.
	*/
	void hold(pw_buffer *b) {
		const Libs &g = libs();
		spa_buffer *buf = b->buffer;
		auto *header = static_cast<spa_meta_header *>(
			spa_buffer_find_meta_data(buf, SPA_META_Header, sizeof(spa_meta_header)));
		const spa_data &d = buf->datas[0];
		if ((header && (header->flags & SPA_META_HEADER_FLAG_CORRUPTED)) || buf->n_datas < 1 ||
		    d.type != SPA_DATA_DmaBuf || !d.chunk || format_ == AV_PIX_FMT_NONE) {
			g.pw_stream_queue_buffer(stream_, b);
			return;
		}
		Dmabuf_Frame f;
		f.buf = b;
		f.fd = static_cast<int>(d.fd);
		f.offset = d.chunk->offset;
		f.stride = d.chunk->stride > 0 ? static_cast<uint32_t>(d.chunk->stride) : width_ * 4;
		f.modifier = modifier_;
		f.format = format_;
		f.width = width_;
		f.height = height_;
		f.w = width_;
		f.h = height_;
		auto *crop = static_cast<spa_meta_region *>(
			spa_buffer_find_meta_data(buf, SPA_META_VideoCrop, sizeof(spa_meta_region)));
		if (crop && spa_meta_region_is_valid(crop) && crop->region.position.x >= 0 &&
		    crop->region.position.y >= 0 &&
		    crop->region.position.x + static_cast<int>(crop->region.size.width) <= width_ &&
		    crop->region.position.y + static_cast<int>(crop->region.size.height) <= height_) {
			f.x = crop->region.position.x;
			f.y = crop->region.position.y;
			f.w = static_cast<int>(crop->region.size.width);
			f.h = static_cast<int>(crop->region.size.height);
		}
		pw_buffer *old = nullptr;
		{
			std::lock_guard<std::mutex> lock(mutex_);
			old = pending_buf_.buf;
			pending_buf_ = f;
			fresh_ = true;
			cv_.notify_one();
		}
		if (old) {
			g.pw_stream_queue_buffer(stream_, old);
		}
	}

	// take copies a buffer's picture out for the share's thread.
	void take(spa_buffer *buf) {
		if (format_ == AV_PIX_FMT_NONE || buf->n_datas < 1) {
			return;
		}
		auto *header = static_cast<spa_meta_header *>(
			spa_buffer_find_meta_data(buf, SPA_META_Header, sizeof(spa_meta_header)));
		if (header && (header->flags & SPA_META_HEADER_FLAG_CORRUPTED)) {
			return;
		}
		const spa_data &d = buf->datas[0];
		if (!d.data || !d.chunk || d.chunk->size == 0) {
			return; // nothing new (only the cursor moved, say)
		}
		int stride = d.chunk->stride > 0 ? d.chunk->stride : width_ * 4;
		int x = 0, y = 0, w = width_, h = height_;
		auto *crop = static_cast<spa_meta_region *>(
			spa_buffer_find_meta_data(buf, SPA_META_VideoCrop, sizeof(spa_meta_region)));
		if (crop && spa_meta_region_is_valid(crop)) {
			x = crop->region.position.x;
			y = crop->region.position.y;
			w = static_cast<int>(crop->region.size.width);
			h = static_cast<int>(crop->region.size.height);
		}
		size_t end = static_cast<size_t>(d.chunk->offset) +
		             static_cast<size_t>(y + h - 1) * stride + static_cast<size_t>(x + w) * 4;
		if (x < 0 || y < 0 || w <= 0 || h <= 0 || x + w > width_ || y + h > height_ ||
		    end > d.maxsize) {
			return;
		}
		const auto *src = static_cast<const uint8_t *>(d.data) + d.chunk->offset;
		Image &img = incoming_;
		img.width = w;
		img.height = h;
		img.stride = w * 4;
		img.format = format_;
		img.data.resize(static_cast<size_t>(img.stride) * h);
		for (int row = 0; row < h; row++) {
			memcpy(&img.data[static_cast<size_t>(row) * img.stride],
			       src + static_cast<size_t>(y + row) * stride + static_cast<size_t>(x) * 4,
			       static_cast<size_t>(w) * 4);
		}
		std::lock_guard<std::mutex> lock(mutex_);
		std::swap(incoming_, pending_);
		fresh_ = true;
		cv_.notify_one();
	}
};

} // namespace

bool portal_usable() {
	static bool usable = [] {
		const Libs &g = libs();
		if (!g.glib || !g.pipewire) {
			return false;
		}
		GDBusConnection *bus = session_bus();
		if (!bus) {
			return false;
		}
		uint32_t version = screencast_property(bus, "version");
		(g.g_object_unref)(bus);
		if (version) {
			log(YV_LOG_INFO, "portal: ScreenCast version %u", version);
		} else {
			log(YV_LOG_INFO, "portal: no ScreenCast");
		}
		return version > 0;
	}();
	return usable;
}

std::unique_ptr<Pipeline> portal_pipeline() {
	return std::make_unique<Portal_Pipeline>();
}

} // namespace yv
