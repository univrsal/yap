package client

import win "core:sys/windows"

// platform_open_url hands the URL to the shell, which opens the default
// browser.
platform_open_url :: proc(url: string) -> bool {
	wurl := win.utf8_to_wstring(url, context.temp_allocator)
	// Values above 32 mean success.
	result := win.ShellExecuteW(nil, win.L("open"), wurl, nil, nil, win.SW_SHOWNORMAL)
	return uintptr(rawptr(result)) > 32
}
