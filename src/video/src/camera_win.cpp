/*
Cameras on Windows, through DirectShow: libdshowcapture (OBS's, LGPL),
built as dshowcapture.dll next to this library and reached through its
plain C face (thirdparty/dshowcapture/yv_dshow.h), loaded the first time
it's needed. Without the DLL there are no cameras, and nothing else
changes.

DirectShow rather than Media Foundation because it sees every camera
Media Foundation does (through the Frame Server, which also shares a
camera between programs) and the virtual ones too, like OBS's, which
are DirectShow filters only. Its frames come in memory, which is where
camera.cpp wants them.

Windows' camera privacy switches aren't asked of DirectShow; they're
read from where Settings keeps them, so that a camera that's turned off
there says so rather than failing to start.
*/
#include "pipeline.h"

#include "../thirdparty/dshowcapture/yv_dshow.h"

#include <windows.h>

#include <objbase.h>
#include <wchar.h>

#include <algorithm>
#include <cmath>
#include <thread>

namespace yv {

namespace {

struct Dshow {
	decltype(&yvds_version) version = nullptr;
	decltype(&yvds_set_log) set_log = nullptr;
	decltype(&yvds_list) list = nullptr;
	decltype(&yvds_open) open = nullptr;
	decltype(&yvds_close) close = nullptr;
	bool ok = false;
};

void dshow_log(void *, int level, const char *msg) {
	// Its information is mostly what it found, which is for debugging.
	yv_log_level ours = level >= 3 ? YV_LOG_ERROR : level == 2 ? YV_LOG_WARN : YV_LOG_DEBUG;
	log(ours, "dshowcapture: %s", msg);
}

template <class T> bool find(HMODULE h, const char *name, T &out) {
	out = reinterpret_cast<T>(reinterpret_cast<void *>(GetProcAddress(h, name)));
	return out != nullptr;
}

const Dshow &dshow() {
	static const Dshow d = [] {
		Dshow d;
		// Next to this library, not wherever the process looks for DLLs.
		static const char here = 0;
		HMODULE self = nullptr;
		GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
		                       GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
		                   reinterpret_cast<LPCWSTR>(&here), &self);
		wchar_t path[MAX_PATH * 4];
		DWORD n = GetModuleFileNameW(self, path, ARRAYSIZE(path));
		std::wstring dll(path, n < ARRAYSIZE(path) ? n : 0);
		dll = dll.substr(0, dll.find_last_of(L"\\/") + 1) + L"dshowcapture.dll";
		HMODULE h = LoadLibraryExW(dll.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
		if (!h) {
			log(YV_LOG_INFO, "camera: no dshowcapture.dll next to yap_video, so no cameras");
			return d;
		}
		if (!find(h, "yvds_version", d.version) || !find(h, "yvds_set_log", d.set_log) ||
		    !find(h, "yvds_list", d.list) || !find(h, "yvds_open", d.open) ||
		    !find(h, "yvds_close", d.close) || d.version() != YVDS_VERSION) {
			log(YV_LOG_WARN, "camera: dshowcapture.dll is of another version, so no cameras");
			FreeLibrary(h);
			return Dshow{};
		}
		d.set_log(dshow_log, nullptr);
		d.ok = true;
		return d;
	}();
	return d;
}

Camera_Format format_of(int32_t f) {
	switch (f) {
	case YVDS_ARGB:
		return Camera_Format::BGRA;
	case YVDS_XRGB:
		return Camera_Format::BGRX;
	case YVDS_RGB24:
		return Camera_Format::BGR24;
	case YVDS_I420:
		return Camera_Format::I420;
	case YVDS_NV12:
		return Camera_Format::NV12;
	case YVDS_YV12:
		return Camera_Format::YV12;
	case YVDS_Y800:
		return Camera_Format::GRAY;
	case YVDS_YVYU:
		return Camera_Format::YVYU;
	case YVDS_YUY2:
		return Camera_Format::YUY2;
	case YVDS_UYVY:
	case YVDS_HDYC: // UYVY in BT.709
		return Camera_Format::UYVY;
	case YVDS_MJPEG:
		return Camera_Format::MJPEG;
	default:
		return Camera_Format::OTHER;
	}
}

int32_t dshow_format(Camera_Format f) {
	switch (f) {
	case Camera_Format::BGRA:
		return YVDS_ARGB;
	case Camera_Format::BGRX:
		return YVDS_XRGB;
	case Camera_Format::BGR24:
		return YVDS_RGB24;
	case Camera_Format::I420:
		return YVDS_I420;
	case Camera_Format::NV12:
		return YVDS_NV12;
	case Camera_Format::YV12:
		return YVDS_YV12;
	case Camera_Format::GRAY:
		return YVDS_Y800;
	case Camera_Format::YVYU:
		return YVDS_YVYU;
	case Camera_Format::YUY2:
		return YVDS_YUY2;
	case Camera_Format::UYVY:
		return YVDS_UYVY;
	case Camera_Format::MJPEG:
		return YVDS_MJPEG;
	case Camera_Format::OTHER:
		break;
	}
	return 0;
}

double fps_of(int64_t interval) {
	return interval > 0 ? 1e7 / static_cast<double>(interval) : 0;
}

// Whether a privacy switch under `root` is off ("Deny"); one that isn't
// there isn't.
bool denied(HKEY root, const wchar_t *key) {
	wchar_t value[16];
	DWORD size = sizeof(value);
	if (RegGetValueW(root, key, L"Value", RRF_RT_REG_SZ, nullptr, value, &size) != ERROR_SUCCESS) {
		return false;
	}
	return _wcsicmp(value, L"Deny") == 0;
}

void camera_frame(void *user, const yvds_frame *f) {
	Camera_Frame frame{format_of(f->format), f->width, f->height, f->data, f->size, f->flip};
	static_cast<Camera_Sink *>(user)->frame(frame);
}

class Source_Win final : public Camera_Source {
public:
	~Source_Win() override {
		if (cam_) {
			dshow().close(cam_);
		}
		if (com_) {
			CoUninitialize();
		}
	}

	bool open(const Camera_Info &camera, const Camera_Mode &mode, int w, int h, double fps,
	          Camera_Sink &sink, std::string &error) override {
		// The share's thread, which this is destroyed on too.
		com_ = SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED));
		yvds_open_config c{};
		c.name = camera.name.c_str();
		c.path = camera.path.c_str();
		c.width = w;
		c.height = h;
		c.interval = std::llround(1e7 / fps);
		c.format = dshow_format(mode.format);
		c.frame = camera_frame;
		c.user = &sink;
		yvds_result result = YVDS_ERROR;
		cam_ = dshow().open(&c, &result);
		if (!cam_) {
			error = result == YVDS_IN_USE ? "another program is using the camera"
			                              : "the camera won't start";
			return false;
		}
		return true;
	}

private:
	yvds_camera *cam_ = nullptr;
	bool com_ = false;
};

} // namespace

std::vector<Camera_Info> list_cameras() {
	std::vector<Camera_Info> out;
	// Listed even while they aren't allowed, so that turning one on says why
	// it can't be (camera.cpp).
	if (!dshow().ok) {
		return out;
	}
	// On a thread of our own, so COM is set up as it needs to be whatever
	// the caller's thread is.
	constexpr int MAX = 16;
	std::vector<yvds_device> devices(MAX);
	int n = 0;
	std::thread([&] {
		bool com = SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED));
		n = dshow().list(devices.data(), MAX);
		if (com) {
			CoUninitialize();
		}
	}).join();
	for (int i = 0; i < std::min(n, MAX); i++) {
		const yvds_device &d = devices[static_cast<size_t>(i)];
		Camera_Info info;
		info.name = d.name;
		info.path = d.path;
		// A virtual camera has no path, and goes by its name.
		copy_name(info.camera.id, sizeof(info.camera.id), info.path.empty() ? info.name : info.path);
		copy_name(info.camera.name, sizeof(info.camera.name), info.name);
		for (int j = 0; j < d.modes_n; j++) {
			const yvds_mode &m = d.modes[j];
			Camera_Mode mode;
			mode.min_width = m.min_width;
			mode.min_height = m.min_height;
			mode.max_width = m.max_width;
			mode.max_height = m.max_height;
			mode.step_width = std::max(1, m.step_width);
			mode.step_height = std::max(1, m.step_height);
			mode.max_fps = fps_of(m.min_interval);
			mode.min_fps = fps_of(m.max_interval);
			mode.format = format_of(m.format);
			if (mode.format == Camera_Format::OTHER) {
				continue;
			}
			info.modes.push_back(mode);
			int64_t area = static_cast<int64_t>(mode.max_width) * mode.max_height;
			int64_t best =
				static_cast<int64_t>(info.camera.max_width) * info.camera.max_height;
			int fps = static_cast<int>(std::lround(mode.max_fps));
			if (area > best || (area == best && fps > info.camera.max_fps)) {
				info.camera.max_width = mode.max_width;
				info.camera.max_height = mode.max_height;
				info.camera.max_fps = fps;
			}
		}
		if (!info.modes.empty()) {
			out.push_back(std::move(info));
		}
	}
	return out;
}

bool camera_allowed(bool, const std::atomic<bool> *) {
	const wchar_t *store =
		L"Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\webcam";
	const wchar_t *desktop = L"Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager"
	                         L"\\ConsentStore\\webcam\\NonPackaged";
	// The whole computer's, the user's for all apps, and for desktop apps.
	return !denied(HKEY_LOCAL_MACHINE, store) && !denied(HKEY_CURRENT_USER, store) &&
	       !denied(HKEY_CURRENT_USER, desktop);
}

std::unique_ptr<Camera_Source> make_camera_source(const Camera_Info &) {
	if (!dshow().ok) {
		return nullptr;
	}
	return std::make_unique<Source_Win>();
}

} // namespace yv
