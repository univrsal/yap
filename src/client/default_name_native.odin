#+build !wasi
package client

import "core:os"

// default_name is the OS user name, as a starting point for the name
// field; "" if there isn't one.
default_name :: proc() -> string {
	for env in ([]string{"USER", "USERNAME", "LOGNAME"}) {
		if name := os.get_env(env, context.temp_allocator); name != "" {
			return name
		}
	}
	return ""
}
