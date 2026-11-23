#+build linux, freebsd, openbsd, netbsd
package settings

import "core:os"
import "core:strings"
import "core:testing"

// test_autostart switches starting at login on and off in a temporary
// configuration directory.
@(test)
test_autostart :: proc(t: ^testing.T) {
	home, err := os.make_directory_temp("", "yap-autostart-*", context.temp_allocator)
	if !testing.expect(t, err == nil) {
		return
	}
	defer os.remove_all(home)
	old_config := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	os.set_env("XDG_CONFIG_HOME", home)
	defer {
		if old_config != "" {
			os.set_env("XDG_CONFIG_HOME", old_config)
		} else {
			os.unset_env("XDG_CONFIG_HOME")
		}
	}
	entry, _ := os.join_path({home, "autostart", "yap.desktop"}, context.temp_allocator)
	exe, _ := os.join_path({home, "some dir", "yap"}, context.temp_allocator)

	_, on := autostart_query(context.temp_allocator)
	testing.expect(t, !on)

	testing.expect_value(t, autostart_set(exe, true), "")
	target, now_on := autostart_query(context.temp_allocator)
	testing.expect(t, now_on)
	testing.expect_value(t, target, exe)
	data, _ := os.read_entire_file(entry, context.temp_allocator)
	testing.expect(
		t,
		strings.contains(
			string(data),
			strings.concatenate({"Exec=\"", exe, "\"\n"}, context.temp_allocator),
		),
	)
	testing.expect(t, strings.contains(string(data), "Type=Application\n"))

	// Switching it on again from another copy points it there.
	other, _ := os.join_path({home, "other", "yap"}, context.temp_allocator)
	testing.expect_value(t, autostart_set(other, true), "")
	target, _ = autostart_query(context.temp_allocator)
	testing.expect_value(t, target, other)

	testing.expect_value(t, autostart_set(exe, false), "")
	_, on = autostart_query(context.temp_allocator)
	testing.expect(t, !on)
	// Off when it is off already is fine.
	testing.expect_value(t, autostart_set(exe, false), "")
}
