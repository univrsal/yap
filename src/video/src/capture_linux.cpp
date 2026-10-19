// Capturing on Linux: choosing how, and converting what's captured
// (capture_linux.h).
#include "capture_linux.h"

#include <cstdlib>
#include <cstring>

#include "ffmpeg.h"

namespace yv {

Capture_Kind capture_kind() {
	static Capture_Kind kind = [] {
		const char *force = getenv("YAP_VIDEO_CAPTURE");
		if (force && strcmp(force, "x11") == 0) {
			return x11_usable() ? Capture_Kind::X11 : Capture_Kind::None;
		}
		if (force && strcmp(force, "portal") == 0) {
			return portal_usable() ? Capture_Kind::Portal : Capture_Kind::None;
		}
		// On Wayland, X11 only sees the windows of XWayland, so the portal
		// comes first there. Without one (WSLg, a bare compositor), what
		// X11 sees is better than nothing.
		const char *wayland = getenv("WAYLAND_DISPLAY");
		const char *session = getenv("XDG_SESSION_TYPE");
		bool on_wayland = (wayland && *wayland) || (session && strcmp(session, "wayland") == 0);
		if (on_wayland && portal_usable()) {
			return Capture_Kind::Portal;
		}
		if (x11_usable()) {
			return Capture_Kind::X11;
		}
		return portal_usable() ? Capture_Kind::Portal : Capture_Kind::None;
	}();
	return kind;
}

std::vector<yv_source> list_sources() {
	switch (capture_kind()) {
	case Capture_Kind::X11:
		return x11_sources();
	case Capture_Kind::Portal: {
		// What's shared is chosen in the portal's picker; this one entry
		// is what starts it.
		yv_source s{};
		s.kind = YV_SOURCE_MONITOR;
		s.id = 0;
		copy_name(s.name, sizeof(s.name), "Screen or window");
		copy_name(s.app, sizeof(s.app), "chosen in the system's picker");
		s.primary = true;
		return {s};
	}
	case Capture_Kind::None:
		break;
	}
	return {};
}

bool system_picker() {
	return capture_kind() == Capture_Kind::Portal;
}

// Nothing to allow here: capturing needs no permission.
bool capture_allowed(bool) {
	return true;
}

bool open_capture_settings() {
	return false;
}

std::unique_ptr<Pipeline> make_pipeline() {
	switch (capture_kind()) {
	case Capture_Kind::X11:
		return x11_pipeline();
	case Capture_Kind::Portal:
		return portal_pipeline();
	case Capture_Kind::None:
		break;
	}
	return nullptr;
}

#ifdef YV_NO_X11
bool x11_usable() {
	return false;
}
std::vector<yv_source> x11_sources() {
	return {};
}
std::unique_ptr<Pipeline> x11_pipeline() {
	return nullptr;
}
#endif

#ifdef YV_NO_PORTAL
bool portal_usable() {
	return false;
}
std::unique_ptr<Pipeline> portal_pipeline() {
	return nullptr;
}
#endif

Memory_Pipeline::~Memory_Pipeline() {
	sws_freeContext(sws_);
	av_frame_free(&nv12_);
	av_buffer_unref(&device_);
}

void Memory_Pipeline::open_device(const char *encoder) {
	if (strstr(encoder, "_vaapi") && vaapi_installed() &&
	    av_hwdevice_ctx_create(&device_, AV_HWDEVICE_TYPE_VAAPI, nullptr, nullptr, 0) < 0) {
		log(YV_LOG_WARN, "share: can't open VA-API");
		device_ = nullptr;
	}
}

AVBufferRef *Memory_Pipeline::hw_device() {
	return device_ ? av_buffer_ref(device_) : nullptr;
}

AVBufferRef *Memory_Pipeline::hw_frames(int w, int h) {
	if (!device_) {
		return nullptr;
	}
	AVBufferRef *ref = av_hwframe_ctx_alloc(device_);
	if (!ref) {
		return nullptr;
	}
	auto *fc = reinterpret_cast<AVHWFramesContext *>(ref->data);
	fc->format = AV_PIX_FMT_VAAPI;
	fc->sw_format = AV_PIX_FMT_NV12;
	fc->width = w;
	fc->height = h;
	fc->initial_pool_size = 0; // grows as the encoder holds on to them
	if (av_hwframe_ctx_init(ref) < 0) {
		log(YV_LOG_WARN, "share: no VA-API surfaces of %dx%d", w, h);
		av_buffer_unref(&ref);
		return nullptr;
	}
	return ref;
}

bool Memory_Pipeline::convert(AVFrame *out, AVBufferRef *frames, int w, int h) {
	const Image &in = latest_;
	if (in.data.empty()) {
		return false;
	}
	// Area averaging when scaling down, so text doesn't shimmer;
	// bilinear otherwise, which at the same size is a plain conversion.
	int flags = (w < in.width || h < in.height) ? SWS_AREA : SWS_BILINEAR;
	sws_ = sws_getCachedContext(sws_, in.width, in.height, in.format, w, h, AV_PIX_FMT_NV12, flags,
	                            nullptr, nullptr, nullptr);
	if (!sws_) {
		return false;
	}
	// RGB is full range whatever it says; out comes BT.709, limited.
	const int *bt709 = sws_getCoefficients(SWS_CS_ITU709);
	sws_setColorspaceDetails(sws_, bt709, 1, bt709, 0, 0, 1 << 16, 1 << 16);

	AVFrame *sw = out;
	if (frames) {
		if (!nv12_) {
			nv12_ = av_frame_alloc();
		}
		if (nv12_->width != w || nv12_->height != h) {
			av_frame_unref(nv12_);
		}
		sw = nv12_;
	}
	if (!sw->data[0]) {
		sw->format = AV_PIX_FMT_NV12;
		sw->width = w;
		sw->height = h;
		if (av_frame_get_buffer(sw, 0) < 0) {
			return false;
		}
	} else if (av_frame_make_writable(sw) < 0) {
		return false;
	}
	const uint8_t *src[1] = {in.data.data()};
	const int stride[1] = {in.stride};
	if (sws_scale(sws_, src, stride, 0, in.height, sw->data, sw->linesize) != h) {
		return false;
	}
	if (!frames) {
		return true;
	}
	if (av_hwframe_get_buffer(frames, out, 0) < 0 || av_hwframe_transfer_data(out, sw, 0) < 0) {
		av_frame_unref(out);
		return false;
	}
	return true;
}

} // namespace yv
