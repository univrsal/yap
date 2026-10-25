#+build !wasi
package conn

import log "common:wlog"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

import "client:settings"
import "common:."
import "common:proto"

// This file keeps pictures on disk between sessions: people's pictures and the
// server's emoji sheet (the blobs fetched with `keep`, see blobs.odin). They are
// available immediately next time instead of being fetched again.
//
// Each picture is a file named by its blob id, in a folder named by the
// server's key (settings.server_key). A server never reuses an id for anything
// else (its blobs table only counts up), and the content under an id never
// changes. A file is first written under a temporary name and then renamed, so
// any file that exists is complete.
//
// When `max_bytes` is exceeded, the pictures used longest ago are removed.
// Using a picture updates its file's timestamp, so this order survives a
// restart. The UI owns the cache and hands it to each connection
// (Blob_Client.disk). The connection loads and stores pictures while the
// settings page shows the cache's size and clears it, which is why a mutex is
// needed.

Image_Cache :: struct {
	mutex:     sync.Mutex,
	dir:       string, // owned; "" when not open
	max_bytes: int, // 0 means nothing is kept
	bytes:     int,
	files:     map[string]Cached_Image, // by settings.server_key; keys owned
	// Pictures that were requested but not yet looked up (see image_cache_request).
	requests:  map[Cache_Request]Requested_Image,
	last:      Cache_Request,
}

@(private = "file")
Requested_Image :: struct {
	server: [proto.KEY_SIZE]u8,
	id:     proto.Blob_Id,
}

@(private = "file")
Cached_Image :: struct {
	size: int,
	used: time.Time,
}

// The suffix of the temporary name a file is written under before it is renamed.
@(private = "file")
PART_SUFFIX :: ".part"

// default_image_cache_dir returns <user cache dir>/yap/images, or "" if the
// system has no cache directory.
default_image_cache_dir :: proc(allocator := context.allocator) -> string {
	dir, err := os.user_cache_dir(context.temp_allocator)
	if err != nil {
		return ""
	}
	path, _ := filepath.join({dir, "yap", "images"}, allocator)
	return path
}

// image_cache_open makes `dir` the cache's folder (creating it if needed) and
// scans what is in it. Any cache that was open before is closed, and its files
// stay where they are.
image_cache_open :: proc(ic: ^Image_Cache, dir: string, max_bytes: int) -> bool {
	sync.guard(&ic.mutex)
	close_locked(ic)
	ic.max_bytes = max(max_bytes, 0)
	if dir == "" {
		return false
	}
	if err := os.make_directory_all(dir); err != nil && !os.is_dir(dir) {
		log.warnf("image cache: could not create %s: %v", dir, err)
		return false
	}
	ic.dir = strings.clone(dir)
	scan(ic)
	trim(ic)
	log.debugf("image cache: %s, %d pictures, %d bytes", ic.dir, len(ic.files), ic.bytes)
	return true
}

image_cache_destroy :: proc(ic: ^Image_Cache) {
	sync.guard(&ic.mutex)
	close_locked(ic)
	delete(ic.files)
	ic.files = nil
	delete(ic.requests)
	ic.requests = nil
}

@(private = "file")
close_locked :: proc(ic: ^Image_Cache) {
	for k in ic.files {
		delete(k)
	}
	clear(&ic.files)
	delete(ic.dir)
	ic.dir = ""
	ic.bytes = 0
}

// image_cache_dir returns the cache's folder, or "" if the cache isn't open.
image_cache_dir :: proc(ic: ^Image_Cache) -> string {
	return ic.dir
}

// image_cache_usage returns the number of bytes the cache takes up and the
// number of pictures in it.
image_cache_usage :: proc(ic: ^Image_Cache) -> (bytes, count: int) {
	sync.guard(&ic.mutex)
	return ic.bytes, len(ic.files)
}

// image_cache_set_max changes the maximum size and drops pictures above it.
image_cache_set_max :: proc(ic: ^Image_Cache, max_bytes: int) {
	sync.guard(&ic.mutex)
	ic.max_bytes = max(max_bytes, 0)
	trim(ic)
}

// image_cache_clear deletes every picture in the cache, and nothing else in its
// folder.
image_cache_clear :: proc(ic: ^Image_Cache) {
	sync.guard(&ic.mutex)
	if ic.dir == "" {
		return
	}
	for k in ic.files {
		os.remove(file_path(ic, k))
	}
	// The servers' folders are removed too if they are now empty.
	if entries, err := os.read_all_directory_by_path(ic.dir, context.temp_allocator); err == nil {
		for e in entries {
			if e.type == .Directory && is_server_dir(e.name) {
				os.remove(e.fullpath)
			}
		}
	}
	for k in ic.files {
		delete(k)
	}
	clear(&ic.files)
	ic.bytes = 0
}

// image_cache_request requests a picture if the cache has it. It returns 0 if
// the cache doesn't have it.
image_cache_request :: proc(
	ic: ^Image_Cache,
	server: [proto.KEY_SIZE]u8,
	id: proto.Blob_Id,
) -> Cache_Request {
	sync.guard(&ic.mutex)
	if settings.server_key(server, u64(id)) not_in ic.files {
		return 0
	}
	ic.last += 1
	ic.requests[ic.last] = {server, id}
	return ic.last
}

// image_cache_poll returns the picture requested with `req`, allocated with
// `allocator`, once the state is Done. A request that is Done or Failed is
// finished.
image_cache_poll :: proc(
	ic: ^Image_Cache,
	req: Cache_Request,
	allocator := context.allocator,
) -> (
	data: []u8,
	state: Cache_Poll,
) {
	sync.mutex_lock(&ic.mutex)
	_, asked := delete_key(&ic.requests, req)
	sync.mutex_unlock(&ic.mutex)
	if asked.id == 0 {
		return nil, .Failed
	}
	read, ok := image_cache_load(ic, asked.server, asked.id, allocator)
	return read, .Done if ok else .Failed
}

// image_cache_cancel cancels the request `req` because the picture is no longer
// wanted.
image_cache_cancel :: proc(ic: ^Image_Cache, req: Cache_Request) {
	sync.guard(&ic.mutex)
	delete_key(&ic.requests, req)
}

// image_cache_load returns a picture from the cache, allocated with
// `allocator`. It returns false if the cache doesn't have it.
image_cache_load :: proc(
	ic: ^Image_Cache,
	server: [proto.KEY_SIZE]u8,
	id: proto.Blob_Id,
	allocator := context.allocator,
) -> (
	data: []u8,
	ok: bool,
) {
	sync.guard(&ic.mutex)
	key := settings.server_key(server, u64(id))
	entry := ic.files[key] or_return
	path := file_path(ic, key)
	read, err := os.read_entire_file(path, allocator)
	if err != nil || len(read) != entry.size {
		log.debugf("image cache: %s is unreadable (%v), dropped it", path, err)
		delete(read, allocator)
		forget(ic, key, remove = true)
		return nil, false
	}
	now := time.now()
	entry.used = now
	ic.files[key] = entry
	os.change_times(path, now, now)
	return read, true
}

// image_cache_store stores a picture, unless it is too big for the cache.
image_cache_store :: proc(
	ic: ^Image_Cache,
	server: [proto.KEY_SIZE]u8,
	id: proto.Blob_Id,
	data: []u8,
) {
	sync.guard(&ic.mutex)
	if ic.dir == "" || len(data) == 0 || len(data) > ic.max_bytes {
		return
	}
	key := settings.server_key(server, u64(id))
	if key in ic.files {
		return
	}
	folder, _ := filepath.join({ic.dir, key[:proto.KEY_SIZE * 2]}, context.temp_allocator)
	if err := os.make_directory_all(folder); err != nil && !os.is_dir(folder) {
		log.warnf("image cache: could not create %s: %v", folder, err)
		return
	}
	path := file_path(ic, key)
	part := strings.concatenate({path, PART_SUFFIX}, context.temp_allocator)
	if err := os.write_entire_file(part, data); err != nil {
		log.warnf("image cache: could not write %s: %v", part, err)
		os.remove(part)
		return
	}
	if err := os.rename(part, path); err != nil {
		log.warnf("image cache: could not rename %s: %v", part, err)
		os.remove(part)
		return
	}
	ic.files[strings.clone(key)] = {
		size = len(data),
		used = time.now(),
	}
	ic.bytes += len(data)
	trim(ic)
}

@(private = "file")
file_path :: proc(ic: ^Image_Cache, key: string) -> string {
	path, _ := filepath.join({ic.dir, key}, context.temp_allocator)
	return path
}

@(private = "file")
forget :: proc(ic: ^Image_Cache, key: string, remove: bool) {
	if remove {
		os.remove(file_path(ic, key))
	}
	owned, entry := delete_key(&ic.files, key)
	ic.bytes -= entry.size
	delete(owned)
}

// trim drops the pictures used longest ago until the rest fits in the cache.
@(private = "file")
trim :: proc(ic: ^Image_Cache) {
	for ic.bytes > ic.max_bytes && len(ic.files) > 0 {
		oldest: string
		oldest_used: time.Time
		for k, e in ic.files {
			if oldest == "" || time.diff(e.used, oldest_used) > 0 {
				oldest, oldest_used = k, e.used
			}
		}
		forget(ic, oldest, remove = true)
	}
}

// scan reads the files in the cache's folder, which has one folder per server
// and one file per picture. Incompletely written files are deleted, and
// anything else is left alone.
@(private = "file")
scan :: proc(ic: ^Image_Cache) {
	servers, err := os.read_all_directory_by_path(ic.dir, context.temp_allocator)
	if err != nil {
		log.warnf("image cache: could not read %s: %v", ic.dir, err)
		return
	}
	for s in servers {
		if s.type != .Directory || !is_server_dir(s.name) {
			continue
		}
		pictures, perr := os.read_all_directory_by_path(s.fullpath, context.temp_allocator)
		if perr != nil {
			continue
		}
		for p in pictures {
			if p.type != .Regular {
				continue
			}
			if strings.has_suffix(p.name, PART_SUFFIX) {
				os.remove(p.fullpath)
				continue
			}
			id, ok := strconv.parse_u64(p.name, 10)
			if !ok || id == 0 || p.size <= 0 {
				continue
			}
			key := strings.concatenate({s.name, "/", p.name})
			if key in ic.files {
				delete(key)
				continue
			}
			ic.files[key] = {
				size = int(p.size),
				used = p.modification_time,
			}
			ic.bytes += int(p.size)
		}
	}
}

// is_server_dir reports whether `name` is a server's key in hex, as written by
// settings.server_key.
@(private = "file")
is_server_dir :: proc(name: string) -> bool {
	_, ok := common.parse_key_hex(name)
	return ok
}
