/*
yv_dshow (yv_dshow.h): libdshowcapture's devices behind plain C, built
into dshowcapture.dll with it, and so under its licence (LGPL 2.1 or
later, COPYING).
*/
#define YV_DSHOW_BUILDING
#include "yv_dshow.h"

#include "dshowcapture.hpp"

#include <windows.h>

#include <algorithm>
#include <cstring>
#include <mutex>
#include <string>

namespace {

std::mutex log_mutex;
yvds_log_fn log_fn = nullptr;
void *log_user = nullptr;

std::string utf8(const std::wstring &w) {
	if (w.empty()) {
		return {};
	}
	int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), nullptr, 0,
	                            nullptr, nullptr);
	std::string s(static_cast<size_t>(n), '\0');
	WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), s.data(), n, nullptr,
	                    nullptr);
	return s;
}

std::wstring wide(const char *s) {
	if (!s || !*s) {
		return {};
	}
	int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, nullptr, 0);
	std::wstring w(static_cast<size_t>(n), L'\0');
	MultiByteToWideChar(CP_UTF8, 0, s, -1, w.data(), n);
	w.resize(static_cast<size_t>(n > 0 ? n - 1 : 0));
	return w;
}

// Copies `s` into a fixed buffer, cut short at a whole UTF-8 character.
void copy_name(char *dst, size_t size, const std::string &s) {
	size_t n = std::min(s.size(), size - 1);
	if (n < s.size()) {
		while (n > 0 && (static_cast<unsigned char>(s[n]) & 0xC0) == 0x80) {
			n--;
		}
	}
	memcpy(dst, s.data(), n);
	dst[n] = 0;
}

void on_log(DShow::LogType type, const wchar_t *msg, void *) {
	int level = 0;
	switch (type) {
	case DShow::LogType::Error:
		level = 3;
		break;
	case DShow::LogType::Warning:
		level = 2;
		break;
	case DShow::LogType::Info:
		level = 1;
		break;
	case DShow::LogType::Debug:
		level = 0;
		break;
	}
	std::string s = utf8(msg ? msg : L"");
	std::lock_guard<std::mutex> lock(log_mutex);
	if (log_fn) {
		log_fn(log_user, level, s.c_str());
	}
}

bool is_rgb(DShow::VideoFormat f) {
	return f == DShow::VideoFormat::ARGB || f == DShow::VideoFormat::XRGB ||
	       f == DShow::VideoFormat::RGB24;
}

} // namespace

struct yvds_camera {
	DShow::Device device{DShow::InitGraph::True};
};

extern "C" {

YV_DSHOW_API int yvds_version(void) {
	return YVDS_VERSION;
}

YV_DSHOW_API void yvds_set_log(yvds_log_fn fn, void *user) {
	{
		std::lock_guard<std::mutex> lock(log_mutex);
		log_fn = fn;
		log_user = user;
	}
	DShow::SetLogCallback(fn ? on_log : nullptr, nullptr);
}

YV_DSHOW_API int yvds_list(yvds_device *out, int max) {
	std::vector<DShow::VideoDevice> devices;
	if (!DShow::Device::EnumVideoDevices(devices)) {
		return 0;
	}
	int n = std::min(static_cast<int>(devices.size()), max);
	for (int i = 0; out && i < n; i++) {
		const DShow::VideoDevice &d = devices[static_cast<size_t>(i)];
		yvds_device &o = out[i];
		memset(&o, 0, sizeof(o));
		copy_name(o.name, sizeof(o.name), utf8(d.name));
		copy_name(o.path, sizeof(o.path), utf8(d.path));
		for (const DShow::VideoInfo &c : d.caps) {
			if (o.modes_n == YVDS_MAX_MODES) {
				break;
			}
			yvds_mode &m = o.modes[o.modes_n++];
			m.min_width = c.minCX;
			m.min_height = c.minCY;
			m.max_width = c.maxCX;
			m.max_height = c.maxCY;
			m.step_width = c.granularityCX;
			m.step_height = c.granularityCY;
			m.min_interval = c.minInterval;
			m.max_interval = c.maxInterval;
			m.format = static_cast<int32_t>(c.format);
		}
	}
	return static_cast<int>(devices.size());
}

YV_DSHOW_API yvds_camera *yvds_open(const yvds_open_config *config, yvds_result *result) {
	yvds_result ignored;
	if (!result) {
		result = &ignored;
	}
	*result = YVDS_ERROR;
	if (!config || !config->frame) {
		return nullptr;
	}
	auto *cam = new yvds_camera;
	if (!cam->device.Valid()) {
		delete cam;
		return nullptr;
	}
	DShow::VideoConfig vc;
	vc.name = wide(config->name);
	vc.path = wide(config->path);
	vc.useDefaultConfig = false;
	vc.cx = config->width;
	vc.cy_abs = config->height;
	vc.frameInterval = config->interval;
	vc.internalFormat = static_cast<DShow::VideoFormat>(config->format);
	vc.format = vc.internalFormat;
	yvds_frame_fn fn = config->frame;
	void *user = config->user;
	vc.callback = [fn, user](const DShow::VideoConfig &c, unsigned char *data, size_t size,
	                         long long start, long long, long) {
		yvds_frame f{};
		f.format = static_cast<int32_t>(c.format);
		f.width = c.cx;
		f.height = c.cy_abs;
		// RGB DIBs are bottom-up unless their height was negative.
		f.flip = is_rgb(c.format) && !c.cy_flip;
		f.data = data;
		f.size = size;
		f.start = start;
		fn(user, &f);
	};
	if (!cam->device.SetVideoConfig(&vc) || !cam->device.ConnectFilters()) {
		delete cam;
		return nullptr;
	}
	DShow::Result r = cam->device.Start();
	if (r != DShow::Result::Success) {
		*result = r == DShow::Result::InUse ? YVDS_IN_USE : YVDS_ERROR;
		delete cam;
		return nullptr;
	}
	*result = YVDS_OK;
	return cam;
}

YV_DSHOW_API void yvds_close(yvds_camera *cam) {
	if (cam) {
		cam->device.Stop();
		delete cam;
	}
}

} // extern "C"
