// Native file dialogs (see yap_dialogs.c and tinydialogs.h, MIT or
// Unlicense). Build the library with build.sh / build.bat at the repo root.
//
// The dialogs block until they are closed. On Linux, the BSDs and Windows they
// can run on a thread of their own; macOS requires them on the main thread.
package dialogs

import "core:strings"

when ODIN_OS == .Windows {
	@(private)
	LIB :: "yap_dialogs.lib"
} else {
	@(private)
	LIB :: "libyap_dialogs.a"
}

when !#exists(LIB) {
	#panic(
		"src/client/dialogs/" +
		LIB +
		" is missing; build it with build.sh (or build.bat on Windows)",
	)
}

when ODIN_OS == .Windows {
	foreign import lib {LIB, "system:ole32.lib", "system:shell32.lib", "system:shlwapi.lib", "system:uuid.lib", "system:user32.lib"}
} else when ODIN_OS == .Darwin {
	foreign import lib {LIB, "system:Cocoa.framework"}
} else {
	foreign import lib {LIB}
}

Status :: enum i32 {
	Ok,
	Cancelled,
	Unavailable, // no dialog program (zenity, kdialog) on this desktop
	Invalid_Argument,
	Failed,
}

// An entry in the dialog's file type list, with patterns like "*.png;*.jpg".
Filter :: struct {
	label:    cstring,
	patterns: cstring,
}

@(private)
Options :: struct {
	title:        cstring,
	initial_path: cstring,
	filters:      [^]Filter,
	filter_count: uint,
}

@(private)
Path_List :: struct {
	items: [^]cstring,
	count: uint,
}

@(default_calling_convention = "c")
foreign lib {
	@(private)
	td_last_error :: proc() -> cstring ---
	@(private)
	td_path_list_free :: proc(paths: ^Path_List) ---
	@(private)
	td_open_file :: proc(options: ^Options, result: ^Path_List) -> Status ---
	@(private)
	td_open_files :: proc(options: ^Options, result: ^Path_List) -> Status ---
}

// open_file asks the user to pick one file to open. The path is allocated with
// `allocator`. When the status is Unavailable or Failed, `err` says what went
// wrong.
open_file :: proc(
	title: string,
	filters: []Filter,
	allocator := context.allocator,
) -> (
	path: string,
	status: Status,
	err: string,
) {
	options := Options {
		title        = strings.clone_to_cstring(title, context.temp_allocator),
		filters      = raw_data(filters),
		filter_count = uint(len(filters)),
	}
	result: Path_List
	status = td_open_file(&options, &result)
	defer td_path_list_free(&result)
	if status == .Ok && result.count > 0 {
		path = strings.clone(string(result.items[0]), allocator)
	}
	if status == .Unavailable || status == .Failed {
		err = strings.clone(string(td_last_error()), allocator)
	}
	return
}

// open_files asks the user to pick any number of files to open. The paths and
// the slice are allocated with `allocator`. `err` works as for open_file.
open_files :: proc(
	title: string,
	filters: []Filter,
	allocator := context.allocator,
) -> (
	paths: []string,
	status: Status,
	err: string,
) {
	options := Options {
		title        = strings.clone_to_cstring(title, context.temp_allocator),
		filters      = raw_data(filters),
		filter_count = uint(len(filters)),
	}
	result: Path_List
	status = td_open_files(&options, &result)
	defer td_path_list_free(&result)
	if status == .Ok && result.count > 0 {
		paths = make([]string, int(result.count), allocator)
		for i in 0 ..< int(result.count) {
			paths[i] = strings.clone(string(result.items[i]), allocator)
		}
	}
	if status == .Unavailable || status == .Failed {
		err = strings.clone(string(td_last_error()), allocator)
	}
	return
}
