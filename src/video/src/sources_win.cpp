/*
What can be shared on Windows: monitors, and the windows a person would
call windows. The filtering follows what the Alt+Tab list shows, which is
what OBS's window list does too (libobs/util/windows/window-helpers.c):
visible, not a tool window or a child, not cloaked (other virtual
desktops, suspended UWP apps), with a title.

Positions and sizes are in physical pixels for monitors. For windows they
are as this process sees them, which is physical pixels when it's per
monitor DPI aware, as the client (GLFW) and yv-loopback are.
*/
#include "internal.h"

#include <windows.h>
#include <dwmapi.h>

namespace yv {

namespace {

std::string utf8(const wchar_t *w, int len = -1) {
	if (!w || len == 0) {
		return {};
	}
	int n = WideCharToMultiByte(CP_UTF8, 0, w, len, nullptr, 0, nullptr, nullptr);
	if (n <= 0) {
		return {};
	}
	std::string s(n, '\0');
	WideCharToMultiByte(CP_UTF8, 0, w, len, s.data(), n, nullptr, nullptr);
	if (len < 0 && !s.empty() && s.back() == '\0') {
		s.pop_back();
	}
	return s;
}

/*
monitor_names maps GDI device names (\\.\DISPLAY1) to what the monitor
calls itself ("DELL U2720Q"), which only the display configuration API
knows.
*/
std::vector<std::pair<std::wstring, std::wstring>> monitor_names() {
	std::vector<std::pair<std::wstring, std::wstring>> names;
	UINT32 npaths = 0, nmodes = 0;
	if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &npaths, &nmodes) != ERROR_SUCCESS) {
		return names;
	}
	std::vector<DISPLAYCONFIG_PATH_INFO> paths(npaths);
	std::vector<DISPLAYCONFIG_MODE_INFO> modes(nmodes);
	if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &npaths, paths.data(), &nmodes, modes.data(),
	                       nullptr) != ERROR_SUCCESS) {
		return names;
	}
	for (UINT32 i = 0; i < npaths; i++) {
		DISPLAYCONFIG_SOURCE_DEVICE_NAME src{};
		src.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
		src.header.size = sizeof(src);
		src.header.adapterId = paths[i].sourceInfo.adapterId;
		src.header.id = paths[i].sourceInfo.id;
		DISPLAYCONFIG_TARGET_DEVICE_NAME target{};
		target.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
		target.header.size = sizeof(target);
		target.header.adapterId = paths[i].targetInfo.adapterId;
		target.header.id = paths[i].targetInfo.id;
		if (DisplayConfigGetDeviceInfo(&src.header) == ERROR_SUCCESS &&
		    DisplayConfigGetDeviceInfo(&target.header) == ERROR_SUCCESS &&
		    target.monitorFriendlyDeviceName[0]) {
			names.emplace_back(src.viewGdiDeviceName, target.monitorFriendlyDeviceName);
		}
	}
	return names;
}

struct Monitor_Search {
	std::vector<yv_source> *out;
	std::vector<std::pair<std::wstring, std::wstring>> names;
};

BOOL CALLBACK add_monitor(HMONITOR mon, HDC, LPRECT, LPARAM param) {
	auto *search = reinterpret_cast<Monitor_Search *>(param);
	MONITORINFOEXW info{};
	info.cbSize = sizeof(info);
	if (!GetMonitorInfoW(mon, &info)) {
		return TRUE;
	}
	yv_source s{};
	s.kind = YV_SOURCE_MONITOR;
	s.id = reinterpret_cast<uint64_t>(mon);
	s.primary = (info.dwFlags & MONITORINFOF_PRIMARY) != 0;
	// The mode gives the real size whatever this process's DPI awareness;
	// the monitor rect would be scaled for one that isn't aware.
	DEVMODEW mode{};
	mode.dmSize = sizeof(mode);
	if (EnumDisplaySettingsW(info.szDevice, ENUM_CURRENT_SETTINGS, &mode)) {
		s.x = mode.dmPosition.x;
		s.y = mode.dmPosition.y;
		s.width = static_cast<int32_t>(mode.dmPelsWidth);
		s.height = static_cast<int32_t>(mode.dmPelsHeight);
	} else {
		s.x = info.rcMonitor.left;
		s.y = info.rcMonitor.top;
		s.width = info.rcMonitor.right - info.rcMonitor.left;
		s.height = info.rcMonitor.bottom - info.rcMonitor.top;
	}
	std::string name;
	for (auto &[device, friendly] : search->names) {
		if (device == info.szDevice) {
			name = utf8(friendly.c_str());
			break;
		}
	}
	if (name.empty()) {
		name = "Monitor " + std::to_string(search->out->size() + 1);
	}
	copy_name(s.name, sizeof(s.name), name);
	copy_name(s.app, sizeof(s.app), utf8(info.szDevice));
	search->out->push_back(s);
	return TRUE;
}

std::wstring class_name(HWND w) {
	wchar_t buf[256];
	int n = GetClassNameW(w, buf, 256);
	return std::wstring(buf, n > 0 ? n : 0);
}

std::string exe_name(DWORD pid) {
	HANDLE proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
	if (!proc) {
		return {};
	}
	wchar_t path[MAX_PATH];
	DWORD len = MAX_PATH;
	std::string name;
	if (QueryFullProcessImageNameW(proc, 0, path, &len)) {
		const wchar_t *base = path;
		for (DWORD i = 0; i < len; i++) {
			if (path[i] == L'\\' || path[i] == L'/') {
				base = path + i + 1;
			}
		}
		name = utf8(base, static_cast<int>(path + len - base));
	}
	CloseHandle(proc);
	return name;
}

/*
A UWP app's window belongs to ApplicationFrameHost.exe; the app is the
process behind its CoreWindow child.
*/
DWORD uwp_pid(HWND frame) {
	DWORD pid = 0;
	EnumChildWindows(
		frame,
		[](HWND child, LPARAM param) -> BOOL {
			if (class_name(child) == L"Windows.UI.Core.CoreWindow") {
				GetWindowThreadProcessId(child, reinterpret_cast<DWORD *>(param));
				return FALSE;
			}
			return TRUE;
		},
		reinterpret_cast<LPARAM>(&pid));
	return pid;
}

bool shareable(HWND w) {
	if (!IsWindowVisible(w)) {
		return false;
	}
	LONG_PTR style = GetWindowLongPtrW(w, GWL_STYLE);
	LONG_PTR exstyle = GetWindowLongPtrW(w, GWL_EXSTYLE);
	if ((style & WS_CHILD) || (exstyle & WS_EX_TOOLWINDOW)) {
		return false;
	}
	DWORD cloaked = 0;
	if (SUCCEEDED(DwmGetWindowAttribute(w, DWMWA_CLOAKED, &cloaked, sizeof(cloaked))) &&
	    cloaked) {
		return false;
	}
	if (GetWindowTextLengthW(w) == 0) {
		return false;
	}
	std::wstring cls = class_name(w);
	// The desktop and the taskbars.
	if (cls == L"Progman" || cls == L"WorkerW" || cls == L"Shell_TrayWnd" ||
	    cls == L"Shell_SecondaryTrayWnd") {
		return false;
	}
	DWORD pid = 0;
	GetWindowThreadProcessId(w, &pid);
	return pid != GetCurrentProcessId();
}

BOOL CALLBACK add_window(HWND w, LPARAM param) {
	if (!shareable(w)) {
		return TRUE;
	}
	RECT r{};
	// The frame as drawn, without the invisible resize borders that
	// GetWindowRect counts.
	if (FAILED(DwmGetWindowAttribute(w, DWMWA_EXTENDED_FRAME_BOUNDS, &r, sizeof(r)))) {
		GetWindowRect(w, &r);
	}
	if (r.right <= r.left || r.bottom <= r.top) {
		return TRUE;
	}
	int len = GetWindowTextLengthW(w);
	std::wstring title(len + 1, L'\0');
	title.resize(GetWindowTextW(w, title.data(), len + 1));

	DWORD pid = 0;
	GetWindowThreadProcessId(w, &pid);
	std::string app = exe_name(pid);
	if (_stricmp(app.c_str(), "ApplicationFrameHost.exe") == 0) {
		if (DWORD real = uwp_pid(w)) {
			app = exe_name(real);
		}
	}

	yv_source s{};
	s.kind = YV_SOURCE_WINDOW;
	s.id = reinterpret_cast<uint64_t>(w);
	s.x = r.left;
	s.y = r.top;
	s.width = r.right - r.left;
	s.height = r.bottom - r.top;
	copy_name(s.name, sizeof(s.name), utf8(title.c_str(), static_cast<int>(title.size())));
	copy_name(s.app, sizeof(s.app), app);
	reinterpret_cast<std::vector<yv_source> *>(param)->push_back(s);
	return TRUE;
}

} // namespace

std::vector<yv_source> list_sources() {
	std::vector<yv_source> out;
	Monitor_Search search{&out, monitor_names()};
	EnumDisplayMonitors(nullptr, nullptr, add_monitor, reinterpret_cast<LPARAM>(&search));
	// EnumWindows goes top to bottom, so the list is in Alt+Tab order.
	EnumWindows(add_window, reinterpret_cast<LPARAM>(&out));
	return out;
}

bool system_picker() {
	return false;
}

// Nothing to allow here: capturing needs no permission.
bool capture_allowed(bool) {
	return true;
}

bool open_capture_settings() {
	return false;
}

} // namespace yv
