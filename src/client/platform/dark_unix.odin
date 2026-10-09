#+build !windows
#+build !wasi
package platform

import "core:os"
import "core:strings"

// Asking means running a program, which can take a while (a D-Bus
// timeout, at worst), so it's done off the UI thread (theme.odin).
PREFERS_DARK_IS_QUICK :: false

/*
prefers_dark is whether the desktop is set to dark mode. On macOS,
`defaults read -g AppleInterfaceStyle` says "Dark" then (and fails when
it's light). Elsewhere the desktop portal's color-scheme setting says,
through busctl: 1 is dark, 2 light and 0 no preference. Without an
answer, light.
*/
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

// run runs `command` (no shell) and gives its output, in the temp
// allocator, if it succeeded.
@(private = "file")
run :: proc(command: []string) -> (out: string, ok: bool) {
	state, stdout, stderr, err := os.process_exec({command = command}, context.temp_allocator)
	if err != nil || !state.exited || state.exit_code != 0 {
		return "", false
	}
	_ = stderr
	return string(stdout), true
}
