#+build !windows
#+build !wasi
package platform

import "core:os"

// locale_name returns the locale that dates and times are written for, as the
// environment names it ("en_US.UTF-8", "de_DE"), or "" if it doesn't. A Mac
// app started from the Finder has none of these, and gets the default.
locale_name :: proc() -> string {
	for env in ([]string{"LC_ALL", "LC_TIME", "LANG"}) {
		if name := os.get_env(env, context.temp_allocator); name != "" {
			return name
		}
	}
	return ""
}
