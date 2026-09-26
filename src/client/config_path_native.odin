#+build !wasi
package client

import "core:os"

// default_config_path returns <config dir>/yap/<name>, or "" if there's
// no config dir. The result lives for the whole run, so it must not come˙˙¸¸
// from the temp allocator: the client loop frees that every iteration.
default_config_path :: proc(name: string, allocator := context.allocator) -> string {
	dir, err := os.user_config_dir(context.temp_allocator)
	if err != nil {
		return ""
	}
	config_dir, _ := os.join_path({dir, "yap"}, context.temp_allocator)
	if mkdir_err := os.make_directory_all(config_dir); mkdir_err != nil && !os.exists(config_dir) {
		return ""
	}
	path, _ := os.join_path({config_dir, name}, allocator)
	return path
}
