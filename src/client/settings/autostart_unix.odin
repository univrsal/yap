#+build linux, freebsd, openbsd, netbsd
package settings

import "core:os"
import "core:strings"

// Starting yap when the user logs in (the client's ui_install_native.odin has
// the checkbox) follows the freedesktop.org autostart spec: a .desktop entry
// in $XDG_CONFIG_HOME/autostart (~/.config/autostart), which the desktop's
// session starts at login. It does not need yap to be installed; the entry
// starts the binary that is running when it is switched on.

@(private = "file")
autostart_path :: proc() -> (path: string, ok: bool) {
	dir, err := os.user_config_dir(context.temp_allocator)
	if err != nil {
		return
	}
	path, _ = os.join_path({dir, "autostart", "yap.desktop"}, context.temp_allocator)
	return path, true
}

// autostart_query returns whether yap starts at login, and the binary that it
// starts ("" if it can't tell).
autostart_query :: proc(allocator := context.allocator) -> (target: string, on: bool) {
	path := autostart_path() or_return
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return
	}
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, "TryExec=") {
			target = desktop_unescape(line[len("TryExec="):], allocator)
		}
	}
	return target, true
}

// autostart_set makes yap start at login, or not.
autostart_set :: proc(exe: string, on: bool) -> (err: string) {
	path, ok := autostart_path()
	if !ok {
		return "Could not find your configuration folder."
	}
	if !on {
		if os.exists(path) && os.remove(path) != nil {
			return strings.concatenate({"Could not remove ", path}, context.temp_allocator)
		}
		return ""
	}
	entry := strings.concatenate(
		{
			"[Desktop Entry]\n",
			"Type=Application\n",
			"Version=1.5\n",
			"Name=Yap\n",
			"Comment=Talk and chat with others on a yap server\n",
			"TryExec=",
			desktop_escape(exe),
			"\n",
			"Exec=",
			desktop_escape(desktop_exec_arg(exe)),
			"\n",
			"Terminal=false\n",
			"X-GNOME-Autostart-enabled=true\n",
		},
		context.temp_allocator,
	)
	if !write_file_all(path, transmute([]u8)entry) {
		return strings.concatenate({"Could not write ", path}, context.temp_allocator)
	}
	return ""
}
