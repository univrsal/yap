package settings

import "core:strings"
import win "core:sys/windows"

// Starting yap when the user logs in (the client's ui_install_native.odin has
// the checkbox) is a value in the current user's Run key, which Windows reads
// at login: Software\Microsoft\Windows\CurrentVersion\Run, "Yap", the quoted
// path of the program. It starts the binary that is running when it is
// switched on, so yap does not need to be installed.

foreign import advapi32 "system:Advapi32.lib"

@(default_calling_convention = "system")
foreign advapi32 {
	RegDeleteValueW :: proc(hKey: win.HKEY, lpValueName: win.LPCWSTR) -> win.LSTATUS ---
}

@(private = "file")
RUN_KEY :: `Software\Microsoft\Windows\CurrentVersion\Run`
@(private = "file")
RUN_VALUE :: "Yap"

// autostart_query returns whether yap starts at login, and the binary that it
// starts ("" if it can't tell).
autostart_query :: proc(allocator := context.allocator) -> (target: string, on: bool) {
	buf: [win.MAX_PATH * 4]u16
	size := win.DWORD(size_of(buf))
	if win.RegGetValueW(
		   win.HKEY_CURRENT_USER,
		   win.utf8_to_wstring(RUN_KEY, context.temp_allocator),
		   win.utf8_to_wstring(RUN_VALUE, context.temp_allocator),
		   win.RRF_RT_REG_SZ,
		   nil,
		   &buf[0],
		   &size,
	   ) !=
	   0 {
		return
	}
	command, _ := win.wstring_to_utf8(win.wstring(&buf[0]), -1, context.temp_allocator)
	return strings.trim(command, `"`), true
}

// autostart_set makes yap start at login, or not.
autostart_set :: proc(exe: string, on: bool) -> (err: string) {
	key: win.HKEY
	if win.RegCreateKeyExW(
		   win.HKEY_CURRENT_USER,
		   win.utf8_to_wstring(RUN_KEY, context.temp_allocator),
		   0,
		   nil,
		   0,
		   win.KEY_SET_VALUE,
		   nil,
		   &key,
		   nil,
	   ) !=
	   0 {
		return "Could not open the list of programs that start at login."
	}
	defer win.RegCloseKey(key)
	name := win.utf8_to_wstring(RUN_VALUE, context.temp_allocator)
	if !on {
		// A value that isn't there is as good as one that was removed.
		status := RegDeleteValueW(key, name)
		if status != 0 && win.DWORD(status) != win.ERROR_FILE_NOT_FOUND {
			return "Could not remove yap from the programs that start at login."
		}
		return ""
	}
	text := strings.concatenate({`"`, exe, `"`}, context.temp_allocator)
	// The size is in bytes and includes the terminating zero.
	wide := make([]u16, len(text) + 1, context.temp_allocator)
	chars := len(win.utf8_to_utf16(wide[:len(text)], text))
	wide[chars] = 0
	if win.RegSetValueExW(
		   key,
		   name,
		   0,
		   win.REG_SZ,
		   (^win.BYTE)(raw_data(wide)),
		   win.DWORD((chars + 1) * size_of(u16)),
	   ) !=
	   0 {
		return "Could not add yap to the programs that start at login."
	}
	return ""
}
