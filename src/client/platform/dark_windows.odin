package platform

import win "core:sys/windows"

// The desktop's own choice is quick to read here, so it needn't be
// asked off the UI thread.
PREFERS_DARK_IS_QUICK :: true

// prefers_dark is whether Windows is set to dark mode for apps: the
// AppsUseLightTheme value is 0 then. Without it (an old Windows), light.
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
