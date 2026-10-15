package platform

import win "core:sys/windows"

// The system's preference is quick to read here, so it doesn't need to be
// queried off the UI thread.
PREFERS_DARK_IS_QUICK :: true

// prefers_dark reports whether Windows is set to dark mode for apps, in which
// case the AppsUseLightTheme value is 0. If the value is missing (older Windows
// versions), light mode is assumed.
prefers_dark :: proc() -> bool {
	value: win.DWORD
	size := win.DWORD(size_of(value))
	status := win.RegGetValueW(
		win.HKEY_CURRENT_USER,
		win.L(`Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`),
		win.L("AppsUseLightTheme"),
		win.RRF_RT_REG_DWORD,
		nil,
		&value,
		&size,
	)
	return status == 0 && value == 0
}
