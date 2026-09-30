#+build wasi
package platform

import "core:strings"

// In a browser there are no directories to put anything in: the name
// itself is what the page's local storage is keyed by, with a prefix so
// yap's entries are recognisable next to anything else the site keeps.
default_config_path :: proc(name: string, allocator := context.allocator) -> string {
	return strings.concatenate({"yap/", name}, allocator)
}

// store_sibling is the store name `name` next to `path`: in the same
// "directory", which here is only the part of the name up to its last
// slash.
store_sibling :: proc(path, name: string, allocator := context.allocator) -> string {
	slash := strings.last_index_byte(path, '/')
	return strings.concatenate({path[:slash + 1], name}, allocator)
}
