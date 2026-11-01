#+build wasi
package script

import "core:encoding/json"
import "core:fmt"
import "core:slice"

import "common:."

// A page has no folder: the scripts are kept in its local storage, and the
// names of them in one more entry, "<dir>/index", a JSON list.
@(private = "file")
index_path :: proc(rt: ^Runtime) -> string {
	return fmt.tprintf("%s/index", rt.dir)
}

list_script_files :: proc(rt: ^Runtime) -> (names: [dynamic]string) {
	names.allocator = context.temp_allocator
	if text, ok := common.store_read(index_path(rt), context.temp_allocator); ok {
		list: []string
		if json.unmarshal(transmute([]u8)text, &list, allocator = context.temp_allocator) == nil {
			for n in list {
				if script_name_ok(n) {
					append(&names, n)
				}
			}
		}
	}
	return
}

@(private = "file")
index_write :: proc(rt: ^Runtime, names: []string) {
	data, err := json.marshal(names, allocator = context.temp_allocator)
	if err == nil {
		common.store_write(index_path(rt), string(data))
	}
}

source_added :: proc(rt: ^Runtime, file: string) {
	names := list_script_files(rt)
	if !slice.contains(names[:], file) {
		append(&names, file)
		index_write(rt, names[:])
	}
}

source_removed :: proc(rt: ^Runtime, file: string) {
	names := list_script_files(rt)
	if i, found := slice.linear_search(names[:], file); found {
		ordered_remove(&names, i)
		index_write(rt, names[:])
	}
}
