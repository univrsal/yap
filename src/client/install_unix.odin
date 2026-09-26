#+build linux, freebsd, openbsd, netbsd
package client

import "core:os"
import "core:strings"

/*
Installing on Linux and the BSDs (see ui_install_native.odin), as the
freedesktop.org specs have it: a .desktop entry in
$XDG_DATA_HOME/applications, which is what puts yap in the desktop's
application menu, with the icon beside it under icons/, and a link to
the binary in ~/.local/bin, which most distributions have on PATH.

The entry is named yap.desktop and the window's app id / WM_CLASS is
"yap" as well (window_open), which is how a Wayland desktop finds the
window's icon and how either kind groups the window under the entry.
*/

INSTALL_DESCRIPTION :: "Adds yap to your desktop's application menu, and a link to it in ~/.local/bin, pointing at this copy of yap; nothing is copied or moved. Uninstall removes them again."

@(private = "file")
Install_Paths :: struct {
	desktop, icon, link: string,
}

// install_paths are the files it installs; all in the temp allocator.
@(private = "file")
install_paths :: proc() -> (p: Install_Paths, ok: bool) {
	data, err := os.user_data_dir(context.temp_allocator)
	if err != nil {
		return
	}
	home, herr := os.user_home_dir(context.temp_allocator)
	if herr != nil {
		return
	}
	p.desktop, _ = os.join_path({data, "applications", "yap.desktop"}, context.temp_allocator)
	p.icon, _ = os.join_path({data, "icons", "hicolor", "128x128", "apps", "yap.png"}, context.temp_allocator)
	p.link, _ = os.join_path({home, ".local", "bin", "yap"}, context.temp_allocator)
	return p, true
}

// install_query reads the binary the entry starts from its TryExec line,
// which also makes the desktop hide the entry if that binary is gone.
install_query :: proc(allocator := context.allocator) -> (target: string, installed: bool) {
	p := install_paths() or_return
	data, err := os.read_entire_file(p.desktop, context.temp_allocator)
	if err != nil {
		return
	}
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, "TryExec=") {
			target = desktop_unescape(line[len("TryExec="):], allocator)
			break
		}
	}
	return target, true
}

install_self :: proc(exe: string) -> (err: string) {
	p, ok := install_paths()
	if !ok {
		return "Could not find your home directory."
	}
	// Whatever the entry pointed at before, so its link can go too.
	old, _ := install_query(context.temp_allocator)

	if !write_file_all(p.icon, ICON_PNG) {
		return strings.concatenate({"Could not write ", p.icon}, context.temp_allocator)
	}
	entry := strings.concatenate(
		{
			"[Desktop Entry]\n",
			"Type=Application\n",
			"Version=1.5\n",
			"Name=Yap\n",
			"GenericName=Voice chat\n",
			"Comment=Talk and chat with others on a yap server\n",
			"TryExec=", desktop_escape(exe), "\n",
			"Exec=", desktop_escape(desktop_exec_arg(exe)), "\n",
			"Icon=", desktop_escape(p.icon), "\n",
			"Terminal=false\n",
			"Categories=Network;Chat;Telephony;\n",
			"Keywords=voice;voip;chat;\n",
			"StartupWMClass=yap\n",
		},
		context.temp_allocator,
	)
	if !write_file_all(p.desktop, transmute([]u8)entry) {
		return strings.concatenate({"Could not write ", p.desktop}, context.temp_allocator)
	}

	// The link is a convenience: if something else already has the name
	// (yap itself, run from there, or another install of it), it's kept.
	if p.link == exe {
		return ""
	}
	if is_our_link(p.link, old, exe) {
		os.remove(p.link)
	}
	if os.exists(p.link) {
		return ""
	}
	dir, _ := os.split_path(p.link)
	os.make_directory_all(dir)
	if os.symlink(exe, p.link) != nil {
		return strings.concatenate({"Installed, but could not make the link ", p.link}, context.temp_allocator)
	}
	return ""
}

uninstall_self :: proc() -> (err: string) {
	p, ok := install_paths()
	if !ok {
		return "Could not find your home directory."
	}
	target, _ := install_query(context.temp_allocator)
	exe, _ := os.get_executable_path(context.temp_allocator)
	if is_our_link(p.link, target, exe) {
		os.remove(p.link)
	}
	os.remove(p.icon)
	if os.exists(p.desktop) && os.remove(p.desktop) != nil {
		return strings.concatenate({"Could not remove ", p.desktop}, context.temp_allocator)
	}
	return ""
}

// is_our_link says whether `link` is a symlink to either of the given
// binaries, rather than a file or a link someone else put there.
@(private = "file")
is_our_link :: proc(link, a, b: string) -> bool {
	fi, err := os.lstat(link, context.temp_allocator)
	if err != nil || fi.type != .Symlink {
		return false
	}
	to, rerr := os.read_link(link, context.temp_allocator)
	return rerr == nil && to != "" && (to == a || to == b)
}

@(private = "file")
write_file_all :: proc(path: string, data: []u8) -> bool {
	dir, _ := os.split_path(path)
	os.make_directory_all(dir)
	return os.write_entire_file(path, data) == nil
}

/*
desktop_exec_arg quotes a path as one argument of an Exec line, which
has its own quoting on top of the escapes every string value has
(desktop_escape): inside double quotes, `"`, "`", `$` and `\` take a
backslash, and `%` (a field code otherwise) is doubled.
*/
desktop_exec_arg :: proc(path: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '"')
	for c in transmute([]u8)path {
		switch c {
		case '"', '`', '$', '\\':
			strings.write_byte(&b, '\\')
			strings.write_byte(&b, c)
		case '%':
			strings.write_string(&b, "%%")
		case:
			strings.write_byte(&b, c)
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

// desktop_escape escapes a string value of a .desktop entry.
desktop_escape :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for c, i in transmute([]u8)s {
		switch c {
		case '\\':
			strings.write_string(&b, `\\`)
		case '\n':
			strings.write_string(&b, `\n`)
		case '\t':
			strings.write_string(&b, `\t`)
		case '\r':
			strings.write_string(&b, `\r`)
		case ' ':
			// Only leading spaces would be lost.
			strings.write_string(&b, `\s` if i == 0 else " ")
		case:
			strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}

// desktop_unescape undoes desktop_escape.
desktop_unescape :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] != '\\' || i + 1 == len(s) {
			strings.write_byte(&b, s[i])
			continue
		}
		i += 1
		switch s[i] {
		case 's':
			strings.write_byte(&b, ' ')
		case 'n':
			strings.write_byte(&b, '\n')
		case 't':
			strings.write_byte(&b, '\t')
		case 'r':
			strings.write_byte(&b, '\r')
		case:
			strings.write_byte(&b, s[i])
		}
	}
	return strings.to_string(b)
}
