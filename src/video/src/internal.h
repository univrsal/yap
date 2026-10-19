// What the library's parts share with each other, but not with clients.
#pragma once

#include "yap_video.h"

#include <mutex>
#include <string>
#include <vector>

namespace yv {
class Output;
}

struct yv_context {
	// yv_set_gpu's, and the views it's passed on to, and the cameras'
	// previews (share.cpp).
	yv_gpu gpu{};
	uint64_t gpu_luid = 0;
	std::mutex views_mutex;
	std::vector<yv_view *> views;
	std::vector<yv::Output *> outputs;

	// yv_list_encoders' findings, made on its first call.
	std::once_flag encoders_probed;
	std::vector<yv_encoder> encoders;
};

namespace yv {

// The log as yv_init set it up. There's one for the whole library
// because FFmpeg's log is global too; the last yv_create sets it.
void log(yv_log_level level, const char *fmt, ...)
#if defined(__GNUC__) || defined(__clang__)
	__attribute__((format(printf, 2, 3)))
#endif
	;
void set_log(yv_log_fn fn, void *user, yv_log_level level);

// While one of these lives, FFmpeg's errors on this thread are only
// debug messages: for trying things that are expected to fail, like
// opening an encoder for hardware that isn't there.
struct Quiet_FFmpeg {
	Quiet_FFmpeg();
	~Quiet_FFmpeg();
	Quiet_FFmpeg(const Quiet_FFmpeg &) = delete;
	Quiet_FFmpeg &operator=(const Quiet_FFmpeg &) = delete;
};

// Copies `s` into a fixed buffer, cut short at a whole UTF-8 character.
void copy_name(char *dst, size_t size, const std::string &s);

// Passes yv_set_gpu on to a view's output (view.cpp).
void view_set_gpu(yv_view *v, const yv_gpu *gpu, uint64_t luid);
uint64_t gpu_luid(const yv_gpu *gpu);

/*
Whether libva is installed. FFmpeg builds like BtbN's reach it through
stubs that abort the whole process when it isn't, rather than failing
the call, so nothing may touch VA-API without asking this first. Always
false on Windows and macOS.
*/
bool vaapi_installed();

/*
YAP_VIDEO_SOFTWARE=1 in the environment turns hardware decoding off, and
makes encoders take frames from memory: to try the ways other machines
take on one that does everything on the GPU.
*/
bool software_only();

std::vector<yv_source> list_sources();
bool system_picker();
bool capture_allowed(bool ask);
bool open_capture_settings();
std::vector<yv_encoder> probe_encoders();

} // namespace yv
