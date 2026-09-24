#+build !wasi
package client

import "core:crypto"
import "core:encoding/hex"
import "core:fmt"
import log "../common/wlog"
import "core:os"
import "core:path/filepath"
import "core:strings"

/*
Saving a chat image to the desktop's downloads folder, under a name of
its own so nothing is ever overwritten.
*/

// save_to_downloads writes `data` as <downloads>/yap-<random>.<ext> and
// returns where it put it.
save_to_downloads :: proc(data: []u8, ext: string, allocator := context.allocator) -> (path: string, ok: bool) {
	dir := downloads_dir(context.temp_allocator)
	if dir == "" {
		log.error("could not work out where the downloads folder is")
		return "", false
	}
	if !os.exists(dir) {
		if err := os.make_directory(dir); err != nil {
			log.errorf("could not create %s: %v", dir, err)
			return "", false
		}
	}
	random: [4]u8
	crypto.rand_bytes(random[:])
	name := fmt.tprintf("yap-%s.%s", string(hex.encode(random[:], context.temp_allocator)), ext)
	path, _ = filepath.join({dir, name}, allocator)
	if err := os.write_entire_file(path, data); err != nil {
		log.errorf("could not save %s: %v", path, err)
		delete(path, allocator)
		return "", false
	}
	return path, true
}

// downloads_dir is the desktop's downloads folder.
@(private = "file")
downloads_dir :: proc(allocator := context.allocator) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	when ODIN_OS == .Windows {
		home = os.get_env("USERPROFILE", context.temp_allocator)
	} else {
		// Freedesktop keeps the (translated, or moved) folder here.
		if dir := os.get_env("XDG_DOWNLOAD_DIR", context.temp_allocator); dir != "" {
			return strings.clone(dir, allocator)
		}
		if dir := user_dirs_download(home); dir != "" {
			return strings.clone(dir, allocator)
		}
	}
	if home == "" {
		return ""
	}
	path, _ := filepath.join({home, "Downloads"}, allocator)
	return path
}

// user_dirs_download reads XDG_DOWNLOAD_DIR out of user-dirs.dirs, whose
// lines look like: XDG_DOWNLOAD_DIR="$HOME/Downloads"
@(private = "file")
user_dirs_download :: proc(home: string) -> string {
	config := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if config == "" {
		if home == "" {
			return ""
		}
		config, _ = filepath.join({home, ".config"}, context.temp_allocator)
	}
	path, _ := filepath.join({config, "user-dirs.dirs"}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return ""
	}
	text := string(data)
	for raw in strings.split_lines_iterator(&text) {
		line := strings.trim_space(raw)
		if !strings.has_prefix(line, "XDG_DOWNLOAD_DIR=") {
			continue
		}
		value := strings.trim(line[len("XDG_DOWNLOAD_DIR="):], `"`)
		if strings.has_prefix(value, "$HOME/") {
			if home == "" {
				return ""
			}
			joined, _ := filepath.join({home, value[len("$HOME/"):]}, context.temp_allocator)
			return joined
		}
		return value
	}
	return ""
}
