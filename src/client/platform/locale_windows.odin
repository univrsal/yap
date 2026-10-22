package platform

import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	GetUserDefaultLocaleName :: proc(lpLocaleName: win.LPWSTR, cchLocaleName: i32) -> i32 ---
}

// locale_name returns the user's locale ("en-US", "de-DE"), or "" if Windows
// doesn't say. In the temp allocator.
locale_name :: proc() -> string {
	buf: [win.LOCALE_NAME_MAX_LENGTH]u16
	n := GetUserDefaultLocaleName(raw_data(buf[:]), len(buf))
	if n <= 1 {
		return ""
	}
	name, err := win.utf16_to_utf8(buf[:n - 1], context.temp_allocator)
	return name if err == nil else ""
}
