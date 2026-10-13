// VA-API's video processor (vpp_linux.h).
#include "vpp_linux.h"
#include "dl_linux.h"
#include "internal.h"

#include <mutex>

#include <va/va.h>
#include <va/va_vpp.h>

extern "C" {
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_vaapi.h>
}

namespace yv {

namespace {

#define VA_FUNCS(X)                                                                                \
	X(vaCreateConfig)                                                                              \
	X(vaDestroyConfig)                                                                             \
	X(vaCreateContext)                                                                             \
	X(vaDestroyContext)                                                                            \
	X(vaCreateBuffer)                                                                              \
	X(vaDestroyBuffer)                                                                             \
	X(vaBeginPicture)                                                                              \
	X(vaRenderPicture)                                                                             \
	X(vaEndPicture)                                                                                \
	X(vaSyncSurface)                                                                               \
	X(vaErrorStr)

struct Va {
	VA_FUNCS(YV_DL_POINTER)
	bool ok = false;
};

const Va &va() {
	static Va v;
	static std::once_flag once;
	std::call_once(once, [] {
		if (!vaapi_installed()) {
			return;
		}
		Va &api = v;
		Dl_Lib lib;
		v.ok = lib.open({"libva.so.2"}) && VA_FUNCS(YV_DL_LOAD) true;
	});
	return v;
}

} // namespace

bool Vpp::available() {
	return va().ok;
}

Vpp::~Vpp() {
	destroy();
}

void Vpp::destroy() {
	const Va &v = va();
	if (context_ != VA_INVALID_ID) {
		v.vaDestroyContext(dpy_, context_);
		context_ = VA_INVALID_ID;
	}
	if (config_ != VA_INVALID_ID) {
		v.vaDestroyConfig(dpy_, config_);
		config_ = VA_INVALID_ID;
	}
	context_w_ = context_h_ = 0;
}

bool Vpp::run(AVBufferRef *device, uint32_t in, int x, int y, int w, int h, uint32_t out,
              int out_w, int out_h) {
	const Va &v = va();
	if (!v.ok || !device) {
		return false;
	}
	auto *dev = reinterpret_cast<AVHWDeviceContext *>(device->data);
	VADisplay dpy = static_cast<AVVAAPIDeviceContext *>(dev->hwctx)->display;
	if (dpy != dpy_ || out_w != context_w_ || out_h != context_h_) {
		destroy();
		dpy_ = dpy;
		VAStatus s = v.vaCreateConfig(dpy, VAProfileNone, VAEntrypointVideoProc, nullptr, 0,
		                              &config_);
		if (s == VA_STATUS_SUCCESS) {
			s = v.vaCreateContext(dpy, config_, out_w, out_h, VA_PROGRESSIVE, nullptr, 0, &context_);
		}
		if (s != VA_STATUS_SUCCESS) {
			log(YV_LOG_WARN, "share: VA-API has no video processor: %s", v.vaErrorStr(s));
			destroy();
			return false;
		}
		context_w_ = out_w;
		context_h_ = out_h;
	}
	VARectangle region{static_cast<int16_t>(x), static_cast<int16_t>(y),
	                   static_cast<uint16_t>(w), static_cast<uint16_t>(h)};
	VAProcPipelineParameterBuffer p{};
	p.surface = in;
	p.surface_region = &region;
	p.surface_color_standard = VAProcColorStandardBT709;
	p.output_color_standard = VAProcColorStandardBT709;
	p.output_background_color = 0xff000000;
	p.filter_flags = VA_FILTER_SCALING_HQ;
	p.input_color_properties.color_range = VA_SOURCE_RANGE_FULL;
	p.output_color_properties.color_range = VA_SOURCE_RANGE_REDUCED;
	VABufferID buf = VA_INVALID_ID;
	VAStatus s = v.vaCreateBuffer(dpy, context_, VAProcPipelineParameterBufferType, sizeof(p), 1,
	                              &p, &buf);
	if (s == VA_STATUS_SUCCESS) {
		s = v.vaBeginPicture(dpy, context_, out);
	}
	if (s == VA_STATUS_SUCCESS) {
		s = v.vaRenderPicture(dpy, context_, &buf, 1);
		VAStatus end = v.vaEndPicture(dpy, context_);
		s = s == VA_STATUS_SUCCESS ? end : s;
	}
	if (buf != VA_INVALID_ID) {
		v.vaDestroyBuffer(dpy, buf);
	}
	// Done before the captured buffer goes back to the compositor.
	if (s == VA_STATUS_SUCCESS) {
		s = v.vaSyncSurface(dpy, out);
	}
	if (s != VA_STATUS_SUCCESS) {
		log(YV_LOG_WARN, "share: VA-API's video processor failed: %s", v.vaErrorStr(s));
		return false;
	}
	return true;
}

} // namespace yv
