#+build !wasi
package script

import "core:os"
import "core:strings"

// The scripts a desktop client knows of are the .lua files in its scripts folder.
list_script_files :: proc(rt: ^Runtime) -> (names: [dynamic]string) {
	names.allocator = context.temp_allocator
	infos, err := os.read_all_directory_by_path(rt.dir, context.temp_allocator)
	if err != nil {
		return
	}
	for fi in infos {
		if fi.type == .Regular && strings.has_suffix(fi.name, ".lua") && script_name_ok(fi.name) {
			append(&names, strings.clone(fi.name, context.temp_allocator))
		}
	}
	return
}

// source_added and source_removed keep the list of scripts, which on a desktop is
// the folder itself.
source_added :: proc(rt: ^Runtime, file: string) {}
source_removed :: proc(rt: ^Runtime, file: string) {}
