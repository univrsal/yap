// The context, logging, and the calls that just ask the platform parts.
#include "internal.h"

#include <algorithm>
#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstring>

#if !defined(_WIN32) && !defined(__APPLE__)
#include <dlfcn.h>
#endif

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/log.h>
}

namespace yv {

namespace {

std::mutex log_mutex;
yv_log_fn log_fn = nullptr;
void *log_user = nullptr;
std::atomic<int> log_min{YV_LOG_INFO};
thread_local int quiet = 0;

void emit(yv_log_level level, const char *msg) {
	std::lock_guard<std::mutex> lock(log_mutex);
	if (log_fn) {
		log_fn(log_user, level, msg);
	}
}

/*
FFmpeg's messages come in pieces, a line at a time at best, so they're
gathered per thread until a newline. Its levels map onto ours, a level
lower; FFmpeg's "info" is mostly chatter.
*/
void ffmpeg_log(void *avcl, int level, const char *fmt, va_list args) {
	yv_log_level ours;
	if (level <= AV_LOG_ERROR) {
		ours = YV_LOG_ERROR;
	} else if (level <= AV_LOG_WARNING) {
		ours = YV_LOG_WARN;
	} else if (level <= AV_LOG_VERBOSE) {
		ours = YV_LOG_DEBUG;
	} else {
		return;
	}
	if (quiet > 0) {
		ours = YV_LOG_DEBUG;
	}
	if (ours < log_min.load()) {
		return;
	}
	thread_local std::string line;
	thread_local int print_prefix = 1;
	char buf[1024];
	av_log_format_line(avcl, level, fmt, args, buf, sizeof(buf), &print_prefix);
	line += buf;
	if (!line.empty() && line.back() == '\n') {
		line.pop_back();
		emit(ours, ("ffmpeg: " + line).c_str());
		line.clear();
	}
}

} // namespace

void set_log(yv_log_fn fn, void *user, yv_log_level level) {
	{
		std::lock_guard<std::mutex> lock(log_mutex);
		log_fn = fn;
		log_user = user;
	}
	log_min.store(level);
	av_log_set_callback(fn ? ffmpeg_log : nullptr);
}

Quiet_FFmpeg::Quiet_FFmpeg() {
	quiet++;
}

Quiet_FFmpeg::~Quiet_FFmpeg() {
	quiet--;
}

void log(yv_log_level level, const char *fmt, ...) {
	if (level < log_min.load()) {
		return;
	}
	char buf[1024];
	va_list args;
	va_start(args, fmt);
	vsnprintf(buf, sizeof(buf), fmt, args);
	va_end(args);
	emit(level, buf);
}

bool vaapi_installed() {
#if defined(_WIN32) || defined(__APPLE__)
	return false;
#else
	static bool installed = [] {
		for (const char *lib : {"libva.so.2", "libva-drm.so.2"}) {
			void *h = dlopen(lib, RTLD_NOW | RTLD_LOCAL);
			if (!h) {
				log(YV_LOG_INFO, "no %s, so no VA-API", lib);
				return false;
			}
			dlclose(h);
		}
		return true;
	}();
	return installed;
#endif
}

void copy_name(char *dst, size_t size, const std::string &s) {
	size_t n = std::min(s.size(), size - 1);
	// Don't end in the middle of a character: back up over continuation
	// bytes to the start of the one that doesn't fit.
	if (n < s.size()) {
		while (n > 0 && (static_cast<unsigned char>(s[n]) & 0xC0) == 0x80) {
			n--;
		}
	}
	memcpy(dst, s.data(), n);
	dst[n] = 0;
}

} // namespace yv

extern "C" {

YV_API uint32_t yv_api_version(void) {
	return YV_API_VERSION;
}

YV_API const char *yv_version_string(void) {
	static std::string s = [] {
		unsigned v = avcodec_version();
		char buf[64];
		snprintf(buf, sizeof(buf), "%d (libavcodec %u.%u.%u)", YV_API_VERSION,
		         AV_VERSION_MAJOR(v), AV_VERSION_MINOR(v), AV_VERSION_MICRO(v));
		return std::string(buf);
	}();
	return s.c_str();
}

YV_API yv_context *yv_create(const yv_init *init) {
	if (!init) {
		return nullptr;
	}
	yv::set_log(init->log, init->log_user, init->log_level);
	if (init->api_version != YV_API_VERSION) {
		yv::log(YV_LOG_ERROR, "client wants API version %u, this is %u", init->api_version,
		        YV_API_VERSION);
		return nullptr;
	}
	auto *ctx = new yv_context;
	yv::log(YV_LOG_INFO, "yap_video %s", yv_version_string());
	return ctx;
}

// The views have to be gone by now.
YV_API void yv_destroy(yv_context *ctx) {
	delete ctx;
}

YV_API void yv_set_gpu(yv_context *ctx, const yv_gpu *gpu) {
	if (!ctx) {
		return;
	}
	yv_gpu g{};
	if (gpu) {
		g = *gpu;
	}
	if ((g.kind == YV_GPU_D3D11 && !g.d3d11_device) || (g.kind == YV_GPU_GL && !g.gl_get_proc) ||
	    (g.kind != YV_GPU_D3D11 && g.kind != YV_GPU_GL)) {
		g = {};
	}
	std::lock_guard<std::mutex> lock(ctx->views_mutex);
	ctx->gpu = g;
	ctx->gpu_luid = yv::gpu_luid(&g);
	for (yv_view *v : ctx->views) {
		yv::view_set_gpu(v, &ctx->gpu, ctx->gpu_luid);
	}
}

YV_API int yv_list_sources(yv_context *ctx, yv_source *out, int max) {
	if (!ctx) {
		return 0;
	}
	std::vector<yv_source> all = yv::list_sources();
	int n = std::min(static_cast<int>(all.size()), max);
	for (int i = 0; out && i < n; i++) {
		out[i] = all[i];
	}
	return static_cast<int>(all.size());
}

YV_API bool yv_system_picker(yv_context *ctx) {
	return ctx && yv::system_picker();
}

YV_API bool yv_capture_allowed(yv_context *ctx, bool ask) {
	return ctx && yv::capture_allowed(ask);
}

YV_API bool yv_open_capture_settings(yv_context *ctx) {
	return ctx && yv::open_capture_settings();
}

YV_API int yv_list_encoders(yv_context *ctx, yv_encoder *out, int max) {
	if (!ctx) {
		return 0;
	}
	std::call_once(ctx->encoders_probed, [ctx] { ctx->encoders = yv::probe_encoders(); });
	int n = std::min(static_cast<int>(ctx->encoders.size()), max);
	for (int i = 0; out && i < n; i++) {
		out[i] = ctx->encoders[i];
	}
	return static_cast<int>(ctx->encoders.size());
}

} // extern "C"
