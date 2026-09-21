#+build wasi
package client

import "core:strings"

// In a browser there are no directories to put anything in: the name
// itself is what the page's local storage is keyed by, with a prefix so
// yap's entries are recognisable next to anything else the site keeps.
default_config_path :: proc(name: string, allocator := context.allocator) -> string {
	return strings.concatenate({"yap/", name}, allocator)
}
