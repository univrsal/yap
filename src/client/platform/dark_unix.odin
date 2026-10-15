#+build !windows
#+build !wasi
package platform

import "core:os"
import "core:strings"

// Querying the setting means running a program, which can take a while (at
// worst until a D-Bus timeout), so it's done off the UI thread (theme.odin).
PREFERS_DARK_IS_QUICK :: false

// prefers_dark reports whether the desktop is set to dark mode. On macOS,
// `defaults read -g AppleInterfaceStyle` prints "Dark" in dark mode (and fails
// in light mode). Elsewhere the desktop portal's color-scheme setting is read
// through busctl: 1 means dark, 2 light and 0 no preference. If there is no
// answer, light mode is assumed.
prefers_dark :: proc() -> bool {
	when ODIN_OS == .Darwin {
		out := run({"defaults", "read", "-g", "AppleInterfaceStyle"}) or_return
		return strings.has_prefix(strings.trim_space(out), "Dark")
	} else {
		out := run(
			{
				"busctl",
				"--user",
				"call",
				"org.freedesktop.portal.Desktop",
				"/org/freedesktop/portal/desktop",
				"org.freedesktop.portal.Settings",
				"Read",
				"ss",
				"org.freedesktop.appearance",
				"color-scheme",
			},
		) or_return
		// The answer is a variant in a variant: "v v u 1" or "v u 1".
		fields := strings.fields(out, context.temp_allocator)
		return len(fields) > 0 && fields[len(fields) - 1] == "1"
	}
}

// run runs `command` (without a shell) and returns its output, allocated in the
// temp allocator, if it succeeded.
@(private = "file")
run :: proc(command: []string) -> (out: string, ok: bool) {
	state, stdout, stderr, err := os.process_exec({command = command}, context.temp_allocator)
	if err != nil || !state.exited || state.exit_code != 0 {
		return "", false
	}
	_ = stderr
	return string(stdout), true
}
