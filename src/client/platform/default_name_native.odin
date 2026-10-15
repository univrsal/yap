#+build !wasi
package platform

import "core:os"

// default_name returns the OS user name, used to prefill the name field, or ""
// if there isn't one.
default_name :: proc() -> string {
	for env in ([]string{"USER", "USERNAME", "LOGNAME"}) {
		if name := os.get_env(env, context.temp_allocator); name != "" {
			return name
		}
	}
	return ""
}
