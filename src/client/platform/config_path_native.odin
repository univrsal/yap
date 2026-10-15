#+build !wasi
package platform

import "core:os"

// default_config_path returns <config dir>/yap/<name>, or "" if there is no
// config dir. The result is kept for the whole run, so it must not be allocated
// in the temp allocator, which the client loop frees every iteration.
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

// store_sibling returns the path of the file `name` in the same directory as
// `path`.
store_sibling :: proc(path, name: string, allocator := context.allocator) -> string {
	joined, _ := os.join_path({os.dir(path), name}, allocator)
	return joined
}
