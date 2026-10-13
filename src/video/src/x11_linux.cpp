/*
Capturing on X11, with XCB rather than Xlib: XCB reports errors per
request instead of through a handler for the whole process, which the
client's own (GLFW's) Xlib connection relies on.

- Monitors come from RandR (1.5's monitors), or the whole screen
  without it. A monitor is captured from the root window; its id holds
  its rectangle, as X11 has no handle for one.
- Windows are the window manager's list (_NET_CLIENT_LIST), less those
  not on screen and our own. A window is captured from its own pixmap
  with Composite, so what's in front of it doesn't matter; a minimised
  one shows its last picture until it's back.
- Pictures are taken with MIT-SHM where the server shares memory with
  us, with plain GetImage otherwise (a remote display, WSLg), at most
  `fps` a second. X11 doesn't say when something changed, so each one
  is compared with the last, and the same picture isn't new.
- The cursor is XFixes' image, drawn in ourselves.

All of XCB is loaded at run time (dl_linux.h); without the extension
libraries, monitors are captured without shared memory or cursor, and
windows not at all.
*/
#include "capture_linux.h"
#include "dl_linux.h"

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <thread>

#include <sys/ipc.h>
#include <sys/shm.h>
#include <unistd.h>

#include <xcb/composite.h>
#include <xcb/randr.h>
#include <xcb/shm.h>
#include <xcb/xcb.h>
#include <xcb/xfixes.h>

namespace yv {

namespace {

#define XCB_CORE(X)                                                                                \
	X(xcb_connect)                                                                                 \
	X(xcb_disconnect)                                                                              \
	X(xcb_connection_has_error)                                                                    \
	X(xcb_get_setup)                                                                               \
	X(xcb_setup_roots_iterator)                                                                    \
	X(xcb_screen_next)                                                                             \
	X(xcb_flush)                                                                                   \
	X(xcb_generate_id)                                                                             \
	X(xcb_request_check)                                                                           \
	X(xcb_get_extension_data)                                                                      \
	X(xcb_intern_atom)                                                                             \
	X(xcb_intern_atom_reply)                                                                       \
	X(xcb_get_property)                                                                            \
	X(xcb_get_property_reply)                                                                      \
	X(xcb_get_property_value)                                                                      \
	X(xcb_get_property_value_length)                                                               \
	X(xcb_get_geometry)                                                                            \
	X(xcb_get_geometry_reply)                                                                      \
	X(xcb_get_window_attributes)                                                                   \
	X(xcb_get_window_attributes_reply)                                                             \
	X(xcb_translate_coordinates)                                                                   \
	X(xcb_translate_coordinates_reply)                                                             \
	X(xcb_get_atom_name)                                                                           \
	X(xcb_get_atom_name_reply)                                                                     \
	X(xcb_get_atom_name_name)                                                                      \
	X(xcb_get_atom_name_name_length)                                                               \
	X(xcb_get_image)                                                                               \
	X(xcb_get_image_reply)                                                                         \
	X(xcb_get_image_data)                                                                          \
	X(xcb_get_image_data_length)                                                                   \
	X(xcb_free_pixmap)                                                                             	X(xcb_query_tree)                                                                              	X(xcb_query_tree_reply)                                                                        	X(xcb_query_tree_children)                                                                     	X(xcb_query_tree_children_length)

#define XCB_SHM(X)                                                                                 \
	X(xcb_shm_id)                                                                                  \
	X(xcb_shm_attach_checked)                                                                      \
	X(xcb_shm_detach)                                                                              \
	X(xcb_shm_get_image)                                                                           \
	X(xcb_shm_get_image_reply)

#define XCB_RANDR(X)                                                                               \
	X(xcb_randr_id)                                                                                \
	X(xcb_randr_query_version)                                                                     \
	X(xcb_randr_query_version_reply)                                                               \
	X(xcb_randr_get_monitors)                                                                      \
	X(xcb_randr_get_monitors_reply)                                                                \
	X(xcb_randr_get_monitors_monitors_iterator)                                                    \
	X(xcb_randr_monitor_info_next)

#define XCB_COMPOSITE(X)                                                                           \
	X(xcb_composite_id)                                                                            \
	X(xcb_composite_query_version)                                                                 \
	X(xcb_composite_query_version_reply)                                                           \
	X(xcb_composite_redirect_window)                                                               \
	X(xcb_composite_unredirect_window)                                                             \
	X(xcb_composite_name_window_pixmap_checked)

#define XCB_XFIXES(X)                                                                              \
	X(xcb_xfixes_id)                                                                               \
	X(xcb_xfixes_query_version)                                                                    \
	X(xcb_xfixes_query_version_reply)                                                              \
	X(xcb_xfixes_get_cursor_image)                                                                 \
	X(xcb_xfixes_get_cursor_image_reply)                                                           \
	X(xcb_xfixes_get_cursor_image_cursor_image)

struct Xcb {
	XCB_CORE(YV_DL_POINTER)
	XCB_SHM(YV_DL_POINTER)
	XCB_RANDR(YV_DL_POINTER)
	XCB_COMPOSITE(YV_DL_POINTER)
	XCB_XFIXES(YV_DL_POINTER)
	bool core = false, shm = false, randr = false, composite = false, xfixes = false;
};

const Xcb &xcb() {
	static Xcb x;
	static std::once_flag once;
	std::call_once(once, [] {
		Xcb &api = x;
		{
			Dl_Lib lib;
			x.core = lib.open({"libxcb.so.1"}) && XCB_CORE(YV_DL_LOAD) true;
		}
		if (!x.core) {
			log(YV_LOG_INFO, "no libxcb, so no X11 capture");
			return;
		}
		{
			Dl_Lib lib;
			x.shm = lib.open({"libxcb-shm.so.0"}) && XCB_SHM(YV_DL_LOAD) true;
		}
		{
			Dl_Lib lib;
			x.randr = lib.open({"libxcb-randr.so.0"}) && XCB_RANDR(YV_DL_LOAD) true;
		}
		{
			Dl_Lib lib;
			x.composite = lib.open({"libxcb-composite.so.0"}) && XCB_COMPOSITE(YV_DL_LOAD) true;
		}
		{
			Dl_Lib lib;
			x.xfixes = lib.open({"libxcb-xfixes.so.0"}) && XCB_XFIXES(YV_DL_LOAD) true;
		}
		log(YV_LOG_DEBUG, "xcb: shm %d, randr %d, composite %d, xfixes %d", x.shm, x.randr,
		    x.composite, x.xfixes);
	});
	return x;
}

// A reply, freed with free() as XCB wants.
template <typename T> struct Reply {
	T *p = nullptr;
	Reply() = default;
	explicit Reply(T *r) : p(r) {}
	Reply(const Reply &) = delete;
	Reply &operator=(const Reply &) = delete;
	Reply(Reply &&o) noexcept : p(o.p) {
		o.p = nullptr;
	}
	Reply &operator=(Reply &&o) noexcept {
		std::swap(p, o.p);
		return *this;
	}
	~Reply() {
		free(p);
	}
	T *operator->() const {
		return p;
	}
	explicit operator bool() const {
		return p != nullptr;
	}
};

// Without the error, which a null reply already says.
template <typename T> Reply<T> reply(T *r, xcb_generic_error_t *err) {
	free(err);
	return Reply<T>(r);
}

// A connection to the default display and its screen.
struct Display {
	const Xcb &x = xcb();
	xcb_connection_t *c = nullptr;
	xcb_screen_t *screen = nullptr;

	bool open() {
		if (!x.core) {
			return false;
		}
		int n = 0;
		c = x.xcb_connect(nullptr, &n);
		if (x.xcb_connection_has_error(c)) {
			return false;
		}
		xcb_screen_iterator_t it = x.xcb_setup_roots_iterator(x.xcb_get_setup(c));
		for (; it.rem && n > 0; n--) {
			x.xcb_screen_next(&it);
		}
		screen = it.rem ? it.data : nullptr;
		return screen != nullptr;
	}

	~Display() {
		if (c) {
			x.xcb_disconnect(c);
		}
	}

	xcb_window_t root() const {
		return screen->root;
	}

	bool has(xcb_extension_t *ext) const {
		const xcb_query_extension_reply_t *r = x.xcb_get_extension_data(c, ext);
		return r && r->present;
	}

	xcb_atom_t atom(const char *name) const {
		auto r = reply(x.xcb_intern_atom_reply(
						   c, x.xcb_intern_atom(c, 0, static_cast<uint16_t>(strlen(name)), name),
						   nullptr),
		               nullptr);
		return r ? r->atom : static_cast<xcb_atom_t>(XCB_ATOM_NONE);
	}

	// The property's value, as bytes; empty if it isn't set.
	std::string property(xcb_window_t w, xcb_atom_t prop, xcb_atom_t type) const {
		auto r = reply(x.xcb_get_property_reply(
						   c, x.xcb_get_property(c, 0, w, prop, type, 0, 1 << 16), nullptr),
		               nullptr);
		if (!r || r->type == XCB_ATOM_NONE) {
			return {};
		}
		const char *v = static_cast<const char *>(x.xcb_get_property_value(r.p));
		int n = x.xcb_get_property_value_length(r.p) * (r->format / 8);
		return std::string(v, static_cast<size_t>(n));
	}

	std::string atom_name(xcb_atom_t a) const {
		auto r = reply(x.xcb_get_atom_name_reply(c, x.xcb_get_atom_name(c, a), nullptr), nullptr);
		if (!r) {
			return {};
		}
		return std::string(x.xcb_get_atom_name_name(r.p),
		                   static_cast<size_t>(x.xcb_get_atom_name_name_length(r.p)));
	}
};

// A monitor's id holds its rectangle; ids aren't 0, as width isn't.
uint64_t monitor_id(int x, int y, int w, int h) {
	return static_cast<uint64_t>(static_cast<uint16_t>(x)) |
	       static_cast<uint64_t>(static_cast<uint16_t>(y)) << 16 |
	       static_cast<uint64_t>(static_cast<uint16_t>(w)) << 32 |
	       static_cast<uint64_t>(static_cast<uint16_t>(h)) << 48;
}

void monitor_rect(uint64_t id, int &x, int &y, int &w, int &h) {
	x = static_cast<int>(id & 0xffff);
	y = static_cast<int>((id >> 16) & 0xffff);
	w = static_cast<int>((id >> 32) & 0xffff);
	h = static_cast<int>((id >> 48) & 0xffff);
}

void list_monitors(Display &d, std::vector<yv_source> &out) {
	const Xcb &x = d.x;
	if (x.randr && d.has(x.xcb_randr_id)) {
		auto v = reply(x.xcb_randr_query_version_reply(
						   d.c, x.xcb_randr_query_version(d.c, 1, 5), nullptr),
		               nullptr);
		if (v && (v->major_version > 1 || v->minor_version >= 5)) {
			auto r = reply(x.xcb_randr_get_monitors_reply(
							   d.c, x.xcb_randr_get_monitors(d.c, d.root(), 1), nullptr),
			               nullptr);
			if (r) {
				xcb_randr_monitor_info_iterator_t it =
					x.xcb_randr_get_monitors_monitors_iterator(r.p);
				for (; it.rem; x.xcb_randr_monitor_info_next(&it)) {
					const xcb_randr_monitor_info_t *m = it.data;
					yv_source s{};
					s.kind = YV_SOURCE_MONITOR;
					s.x = m->x;
					s.y = m->y;
					s.width = m->width;
					s.height = m->height;
					s.id = monitor_id(s.x, s.y, s.width, s.height);
					s.primary = m->primary != 0;
					std::string name = d.atom_name(m->name);
					copy_name(s.name, sizeof(s.name), name);
					copy_name(s.app, sizeof(s.app), name);
					out.push_back(s);
				}
				if (!out.empty()) {
					return;
				}
			}
		}
	}
	// The whole screen, as one.
	yv_source s{};
	s.kind = YV_SOURCE_MONITOR;
	s.width = d.screen->width_in_pixels;
	s.height = d.screen->height_in_pixels;
	s.id = monitor_id(0, 0, s.width, s.height);
	s.primary = true;
	copy_name(s.name, sizeof(s.name), "Screen");
	copy_name(s.app, sizeof(s.app), "screen");
	out.push_back(s);
}

// children lists a window's children, bottom first.
std::vector<xcb_window_t> children(Display &d, xcb_window_t w) {
	const Xcb &x = d.x;
	auto r = reply(x.xcb_query_tree_reply(d.c, x.xcb_query_tree(d.c, w), nullptr), nullptr);
	if (!r) {
		return {};
	}
	const xcb_window_t *c = x.xcb_query_tree_children(r.p);
	return std::vector<xcb_window_t>(c, c + x.xcb_query_tree_children_length(r.p));
}

/*
client_windows is the window manager's list of windows, or without one
that keeps it (WSLg's), the windows with WM_STATE among the root's
children and theirs, which is where ICCCM puts them.
*/
std::vector<xcb_window_t> client_windows(Display &d, xcb_atom_t client_list) {
	std::string list = d.property(d.root(), client_list, XCB_ATOM_WINDOW);
	std::vector<xcb_window_t> out(list.size() / 4);
	if (!out.empty()) {
		memcpy(out.data(), list.data(), out.size() * 4);
		return out;
	}
	xcb_atom_t wm_state = d.atom("WM_STATE");
	auto managed = [&](xcb_window_t w) { return !d.property(w, wm_state, wm_state).empty(); };
	std::vector<xcb_window_t> top = children(d, d.root());
	for (auto it = top.rbegin(); it != top.rend(); ++it) {
		if (managed(*it)) {
			out.push_back(*it);
			continue;
		}
		for (xcb_window_t c : children(d, *it)) {
			if (managed(c)) {
				out.push_back(c);
				break;
			}
		}
	}
	return out;
}

void list_windows(Display &d, std::vector<yv_source> &out) {
	const Xcb &x = d.x;
	if (!x.composite || !d.has(x.xcb_composite_id)) {
		return; // can't capture them anyway
	}
	xcb_atom_t client_list = d.atom("_NET_CLIENT_LIST");
	xcb_atom_t net_name = d.atom("_NET_WM_NAME");
	xcb_atom_t utf8 = d.atom("UTF8_STRING");
	xcb_atom_t net_pid = d.atom("_NET_WM_PID");
	xcb_atom_t type = d.atom("_NET_WM_WINDOW_TYPE");
	xcb_atom_t type_dock = d.atom("_NET_WM_WINDOW_TYPE_DOCK");
	xcb_atom_t type_desktop = d.atom("_NET_WM_WINDOW_TYPE_DESKTOP");
	std::vector<xcb_window_t> list = client_windows(d, client_list);
	uint32_t me = static_cast<uint32_t>(getpid());
	for (xcb_window_t w : list) {
		auto attrs = reply(x.xcb_get_window_attributes_reply(
							   d.c, x.xcb_get_window_attributes(d.c, w), nullptr),
		                   nullptr);
		if (!attrs || attrs->map_state != XCB_MAP_STATE_VIEWABLE) {
			continue;
		}
		std::string pid = d.property(w, net_pid, XCB_ATOM_CARDINAL);
		if (pid.size() == 4 && memcmp(pid.data(), &me, 4) == 0) {
			continue;
		}
		std::string types = d.property(w, type, XCB_ATOM_ATOM);
		bool skip = false;
		for (size_t t = 0; t + 4 <= types.size(); t += 4) {
			xcb_atom_t a;
			memcpy(&a, types.data() + t, 4);
			skip = skip || a == type_dock || a == type_desktop;
		}
		if (skip) {
			continue;
		}
		auto geo = reply(x.xcb_get_geometry_reply(d.c, x.xcb_get_geometry(d.c, w), nullptr),
		                 nullptr);
		auto pos = reply(x.xcb_translate_coordinates_reply(
							 d.c, x.xcb_translate_coordinates(d.c, w, d.root(), 0, 0), nullptr),
		                 nullptr);
		if (!geo || !pos) {
			continue;
		}
		std::string title = d.property(w, net_name, utf8);
		if (title.empty()) {
			title = d.property(w, XCB_ATOM_WM_NAME, XCB_ATOM_STRING);
		}
		// WM_CLASS is the instance and the class, each ending in a zero.
		std::string cls = d.property(w, XCB_ATOM_WM_CLASS, XCB_ATOM_STRING);
		std::string app = cls.substr(0, cls.find('\0'));
		if (size_t second = cls.find('\0'); second != std::string::npos && second + 1 < cls.size()) {
			app = cls.substr(second + 1);
			app = app.substr(0, app.find('\0'));
		}
		if (title.empty()) {
			title = app;
		}
		yv_source s{};
		s.kind = YV_SOURCE_WINDOW;
		s.id = w;
		copy_name(s.name, sizeof(s.name), title);
		copy_name(s.app, sizeof(s.app), app);
		s.x = pos->dst_x;
		s.y = pos->dst_y;
		s.width = geo->width;
		s.height = geo->height;
		out.push_back(s);
	}
}

using Clock = std::chrono::steady_clock;

class X11_Pipeline : public Memory_Pipeline {
public:
	~X11_Pipeline() override {
		detach_shm();
		if (pixmap_) {
			d_.x.xcb_free_pixmap(d_.c, pixmap_);
		}
		if (redirected_) {
			d_.x.xcb_composite_unredirect_window(d_.c, window_,
			                                     XCB_COMPOSITE_REDIRECT_AUTOMATIC);
		}
		if (d_.c) {
			d_.x.xcb_flush(d_.c);
		}
	}

	bool open(const yv_share_config &config, const char *encoder, const std::atomic<bool> &,
	          std::string &error) override {
		if (!d_.open()) {
			error = "can't reach the X server";
			return false;
		}
		const Xcb &x = d_.x;
		interval_ = std::chrono::microseconds(1'000'000 / std::max(1, config.fps));
		if (config.kind == YV_SOURCE_WINDOW) {
			if (!x.composite || !d_.has(x.xcb_composite_id)) {
				error = "capturing a window needs the X server's Composite extension";
				return false;
			}
			window_ = static_cast<xcb_window_t>(config.source);
			// Says which version we speak, which servers want first.
			reply(x.xcb_composite_query_version_reply(
					  d_.c, x.xcb_composite_query_version(d_.c, 0, 4), nullptr),
			      nullptr);
			x.xcb_composite_redirect_window(d_.c, window_, XCB_COMPOSITE_REDIRECT_AUTOMATIC);
			redirected_ = true;
		} else {
			monitor_rect(config.source, mon_x_, mon_y_, mon_w_, mon_h_);
			if (mon_w_ <= 0 || mon_h_ <= 0 || mon_x_ + mon_w_ > d_.screen->width_in_pixels ||
			    mon_y_ + mon_h_ > d_.screen->height_in_pixels) {
				error = "that monitor isn't there any more";
				return false;
			}
		}
		use_shm_ = x.shm && d_.has(x.xcb_shm_id) && !getenv("YAP_VIDEO_NO_SHM");
		if (config.cursor && x.xfixes && d_.has(x.xcb_xfixes_id)) {
			auto v = reply(x.xcb_xfixes_query_version_reply(
							   d_.c, x.xcb_xfixes_query_version(d_.c, 4, 0), nullptr),
			               nullptr);
			cursor_ = static_cast<bool>(v);
		}
		open_device(encoder);
		log(YV_LOG_INFO, "share: capturing X11 %s %#llx%s%s",
		    window_ ? "window" : "monitor", static_cast<unsigned long long>(config.source),
		    use_shm_ ? " with shared memory" : "", cursor_ ? ", with the cursor" : "");
		next_ = Clock::now();
		return true;
	}

	bool wait(int ms, bool &closed) override {
		closed = false;
		auto now = Clock::now();
		auto until = now + std::chrono::milliseconds(ms);
		if (next_ > now) {
			std::this_thread::sleep_until(std::min(next_, until));
			now = Clock::now();
			if (next_ > now) {
				return false;
			}
		}
		// On the beat, unless we've fallen behind it.
		next_ = std::max(next_ + interval_, now);
		return grab(closed);
	}

private:
	Display d_;
	std::chrono::microseconds interval_{16'666};
	Clock::time_point next_;

	int mon_x_ = 0, mon_y_ = 0, mon_w_ = 0, mon_h_ = 0;
	xcb_window_t window_ = 0;
	bool redirected_ = false;
	xcb_pixmap_t pixmap_ = 0;
	int pixmap_w_ = 0, pixmap_h_ = 0;
	bool cursor_ = false;

	bool use_shm_ = false;
	xcb_shm_seg_t seg_ = 0;
	uint8_t *shm_ = nullptr;
	size_t shm_size_ = 0;

	Image grabbed_; // the picture being taken, swapped with latest_ if new
	bool failed_ = false; // grab_failed said so

	void detach_shm() {
		if (shm_) {
			d_.x.xcb_shm_detach(d_.c, seg_);
			shmdt(shm_);
			shm_ = nullptr;
			shm_size_ = 0;
		}
	}

	// attach_shm makes a shared segment of at least `size`, or says
	// there can't be one, after which GetImage does.
	bool attach_shm(size_t size) {
		if (shm_ && shm_size_ >= size) {
			return true;
		}
		detach_shm();
		int id = shmget(IPC_PRIVATE, size, IPC_CREAT | 0600);
		if (id < 0) {
			use_shm_ = false;
			return false;
		}
		void *p = shmat(id, nullptr, 0);
		seg_ = d_.x.xcb_generate_id(d_.c);
		xcb_generic_error_t *err =
			p == reinterpret_cast<void *>(-1)
				? nullptr
				: d_.x.xcb_request_check(d_.c, d_.x.xcb_shm_attach_checked(
												   d_.c, seg_, static_cast<uint32_t>(id), 0));
		// Gone once both sides let go of it.
		shmctl(id, IPC_RMID, nullptr);
		if (p == reinterpret_cast<void *>(-1) || err) {
			free(err);
			if (p != reinterpret_cast<void *>(-1)) {
				shmdt(p);
			}
			log(YV_LOG_INFO, "share: the X server can't share memory with us; using GetImage");
			use_shm_ = false;
			return false;
		}
		shm_ = static_cast<uint8_t *>(p);
		shm_size_ = size;
		return true;
	}

	// grab takes a picture, and says whether it differs from the last.
	bool grab(bool &closed) {
		const Xcb &x = d_.x;
		xcb_drawable_t from = d_.root();
		int sx = mon_x_, sy = mon_y_, w = mon_w_, h = mon_h_;
		int origin_x = mon_x_, origin_y = mon_y_; // on the root, for the cursor
		if (window_) {
			auto geo = reply(x.xcb_get_geometry_reply(d_.c, x.xcb_get_geometry(d_.c, window_),
			                                          nullptr),
			                 nullptr);
			if (!geo) {
				closed = true;
				return false;
			}
			w = geo->width;
			h = geo->height;
			if (!pixmap_ || w != pixmap_w_ || h != pixmap_h_) {
				if (pixmap_) {
					x.xcb_free_pixmap(d_.c, pixmap_);
					pixmap_ = 0;
				}
				xcb_pixmap_t p = x.xcb_generate_id(d_.c);
				xcb_generic_error_t *err = x.xcb_request_check(
					d_.c, x.xcb_composite_name_window_pixmap_checked(d_.c, window_, p));
				if (err) {
					free(err); // not on screen (minimised): keep what we have
					return false;
				}
				pixmap_ = p;
				pixmap_w_ = w;
				pixmap_h_ = h;
			}
			// The pixmap has the border round the window too.
			from = pixmap_;
			sx = sy = geo->border_width;
			auto pos = reply(x.xcb_translate_coordinates_reply(
								 d_.c, x.xcb_translate_coordinates(d_.c, window_, d_.root(), 0, 0),
								 nullptr),
			                 nullptr);
			if (pos) {
				origin_x = pos->dst_x;
				origin_y = pos->dst_y;
			}
		}
		size_t size = static_cast<size_t>(w) * h * 4;
		const uint8_t *pixels = nullptr;
		Reply<xcb_get_image_reply_t> plain;
		xcb_generic_error_t *err = nullptr;
		if (use_shm_ && attach_shm(size)) {
			Reply<xcb_shm_get_image_reply_t> r(x.xcb_shm_get_image_reply(
				d_.c,
				x.xcb_shm_get_image(d_.c, from, static_cast<int16_t>(sx), static_cast<int16_t>(sy),
			                        static_cast<uint16_t>(w), static_cast<uint16_t>(h), ~0u,
			                        XCB_IMAGE_FORMAT_Z_PIXMAP, seg_, 0),
				&err));
			if (!r || r->size != size) {
				// The pixmap went (the window was unmapped in between).
				grab_failed(err, r ? r->depth : 0);
				return false;
			}
			pixels = shm_;
		} else {
			plain = Reply<xcb_get_image_reply_t>(x.xcb_get_image_reply(
				d_.c,
				x.xcb_get_image(d_.c, XCB_IMAGE_FORMAT_Z_PIXMAP, from, static_cast<int16_t>(sx),
			                    static_cast<int16_t>(sy), static_cast<uint16_t>(w),
			                    static_cast<uint16_t>(h), ~0u),
				&err));
			if (!plain || static_cast<size_t>(x.xcb_get_image_data_length(plain.p)) != size) {
				grab_failed(err, plain ? plain->depth : 0);
				return false;
			}
			pixels = x.xcb_get_image_data(plain.p);
		}
		// 24 and 32 bit depths are 32 bits a pixel, blue first.
		Image &g = grabbed_;
		g.width = w;
		g.height = h;
		g.stride = w * 4;
		g.format = AV_PIX_FMT_BGR0;
		g.data.assign(pixels, pixels + size);
		if (cursor_) {
			draw_cursor(g, origin_x, origin_y);
		}
		const Image &l = latest_;
		if (l.width == g.width && l.height == g.height && l.data == g.data) {
			return false;
		}
		std::swap(latest_, grabbed_);
		return true;
	}

	// grab_failed lets go of the pixmap, which may be what went, and
	// says why the first time.
	void grab_failed(xcb_generic_error_t *err, int depth) {
		if (!failed_) {
			failed_ = true;
			if (err) {
				log(YV_LOG_WARN, "share: X11 won't give the picture (error %d)", err->error_code);
			} else {
				log(YV_LOG_WARN, "share: X11 gave a picture of depth %d, which we can't use",
				    depth);
			}
		}
		free(err);
		drop_pixmap();
	}

	void drop_pixmap() {
		if (pixmap_) {
			d_.x.xcb_free_pixmap(d_.c, pixmap_);
			pixmap_ = 0;
		}
	}

	// draw_cursor draws the pointer into `g`, whose top left is at
	// origin_x, origin_y on the root window.
	void draw_cursor(Image &g, int origin_x, int origin_y) {
		const Xcb &x = d_.x;
		auto r = reply(x.xcb_xfixes_get_cursor_image_reply(
						   d_.c, x.xcb_xfixes_get_cursor_image(d_.c), nullptr),
		               nullptr);
		if (!r) {
			return;
		}
		// Premultiplied ARGB, a pixel to a 32 bit number.
		const uint32_t *px = x.xcb_xfixes_get_cursor_image_cursor_image(r.p);
		int left = r->x - r->xhot - origin_x;
		int top = r->y - r->yhot - origin_y;
		for (int cy = 0; cy < r->height; cy++) {
			int y = top + cy;
			if (y < 0 || y >= g.height) {
				continue;
			}
			for (int cx = 0; cx < r->width; cx++) {
				int xx = left + cx;
				if (xx < 0 || xx >= g.width) {
					continue;
				}
				uint32_t c = px[cy * r->width + cx];
				uint32_t a = c >> 24;
				if (a == 0) {
					continue;
				}
				uint8_t *d = &g.data[static_cast<size_t>(y) * g.stride + xx * 4];
				for (int ch = 0; ch < 3; ch++) {
					uint32_t s = (c >> (8 * ch)) & 0xff;
					d[ch] = static_cast<uint8_t>(s + d[ch] * (255 - a) / 255);
				}
			}
		}
	}
};

} // namespace

bool x11_usable() {
	static bool usable = [] {
		const char *display = getenv("DISPLAY");
		if (!display || !*display) {
			return false;
		}
		Display d;
		return d.open();
	}();
	return usable;
}

std::vector<yv_source> x11_sources() {
	std::vector<yv_source> out;
	Display d;
	if (!d.open()) {
		return out;
	}
	list_monitors(d, out);
	list_windows(d, out);
	return out;
}

std::unique_ptr<Pipeline> x11_pipeline() {
	return std::make_unique<X11_Pipeline>();
}

} // namespace yv
