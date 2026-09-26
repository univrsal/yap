#+build linux, freebsd, openbsd, netbsd
package client

import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_desktop_escapes :: proc(t: ^testing.T) {
	testing.expect_value(t, desktop_exec_arg("/usr/bin/yap"), `"/usr/bin/yap"`)
	testing.expect_value(t, desktop_exec_arg(`/a b/$x"y\z%`), `"/a b/\$x\"y\\z%%"`)
	// The Exec line's own quoting goes through the string escapes too.
	testing.expect_value(t, desktop_escape(desktop_exec_arg(`/a\b`)), `"/a\\\\b"`)
	testing.expect_value(t, desktop_escape(" a b\n"), `\sa b\n`)
	for s in ([]string{"/usr/bin/yap", ` /odd\ path/`, "/new\nline\t"}) {
		testing.expect_value(t, desktop_unescape(desktop_escape(s), context.temp_allocator), s)
	}
}

// test_install_self installs into a home directory of its own, and
// uninstalls again.
@(test)
test_install_self :: proc(t: ^testing.T) {
	home, err := os.make_directory_temp("", "yap-install-*", context.temp_allocator)
	if !testing.expect(t, err == nil) {
		return
	}
	defer os.remove_all(home)
	old_home := os.get_env("HOME", context.temp_allocator)
	old_data := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	os.set_env("HOME", home)
	os.unset_env("XDG_DATA_HOME")
	defer {
		os.set_env("HOME", old_home)
		if old_data != "" {
			os.set_env("XDG_DATA_HOME", old_data)
		}
	}

	path :: proc(parts: ..string) -> string {
		p, _ := os.join_path(parts, context.temp_allocator)
		return p
	}
	desktop := path(home, ".local", "share", "applications", "yap.desktop")
	icon := path(home, ".local", "share", "icons", "hicolor", "128x128", "apps", "yap.png")
	link := path(home, ".local", "bin", "yap")
	exe := path(home, "some dir", "yap")

	_, installed := install_query(context.temp_allocator)
	testing.expect(t, !installed)

	testing.expect_value(t, install_self(exe), "")
	target, now_installed := install_query(context.temp_allocator)
	testing.expect(t, now_installed)
	testing.expect_value(t, target, exe)
	testing.expect(t, os.exists(icon))
	to, _ := os.read_link(link, context.temp_allocator)
	testing.expect_value(t, to, exe)
	data, _ := os.read_entire_file(desktop, context.temp_allocator)
	testing.expect(t, strings.contains(string(data), strings.concatenate({"Exec=\"", exe, "\"\n"}, context.temp_allocator)))

	// Installing another copy moves the link along with the entry.
	other := path(home, "other", "yap")
	testing.expect_value(t, install_self(other), "")
	to, _ = os.read_link(link, context.temp_allocator)
	testing.expect_value(t, to, other)

	testing.expect_value(t, uninstall_self(), "")
	_, installed = install_query(context.temp_allocator)
	testing.expect(t, !installed)
	testing.expect(t, !os.exists(icon))
	_, lerr := os.lstat(link, context.temp_allocator)
	testing.expect(t, lerr != nil)

	// A file of someone else's in the link's place is left alone.
	testing.expect(t, os.write_entire_file(link, "not ours") == nil)
	testing.expect_value(t, install_self(exe), "")
	testing.expect_value(t, uninstall_self(), "")
	kept, _ := os.read_entire_file(link, context.temp_allocator)
	testing.expect_value(t, string(kept), "not ours")
}
