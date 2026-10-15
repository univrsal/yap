#+build wasi
package platform

import "core:strings"

// A browser has no directories to put files in, so the name itself is used as
// the key in the page's local storage. The "yap/" prefix makes yap's entries
// recognisable among anything else the site stores.
default_config_path :: proc(name: string, allocator := context.allocator) -> string {
	return strings.concatenate({"yap/", name}, allocator)
}

// store_sibling returns the store name `name` next to `path`, i.e. in the same
// "directory", which here is just the part of `path` up to its last slash.
store_sibling :: proc(path, name: string, allocator := context.allocator) -> string {
	slash := strings.last_index_byte(path, '/')
	return strings.concatenate({path[:slash + 1], name}, allocator)
}
