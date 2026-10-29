package server

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

import "common:avatar"
import "curl"
import "mattermost"
import "webpush"

// The pictures that integrations pose with (docs/design/mattermost-import.md,
// step 10): `override_icon_url` is an address that every client of Mattermost
// fetched. yap's personas have a picture of the server's own (a blob), so the
// importer fetches each address once, if it is asked to (--fetch-icons): it is
// the one thing that makes the importer connect to addresses that an export
// names, which could be anywhere, including this machine's own network. So it
// only connects to the public internet (the address check that push uses, on
// every connection, redirects included), speaks only HTTP and HTTPS, and takes
// little: a few seconds and 2 MB for each address.

// The most addresses that are fetched, the most used first, how long all of them
// may take, and what each may: a few seconds, a redirect or three and bytes.
ICONS_MOST :: 100
ICONS_BUDGET :: 5 * time.Minute
ICON_CONNECT_TIMEOUT :: 5 // seconds
ICON_TIMEOUT :: 10 // seconds
ICON_REDIRECTS :: 3
ICON_MAX_SIZE :: 2 * 1024 * 1024

// Fetching is what an importer is given to do with the network, so that a test
// can have it speak to a server of its own, which isn't on the public internet.
Icon_Options :: struct {
	// Also connect to addresses that aren't public (tests).
	allow_private: bool,
}

@(private = "file")
Icon_Socket :: struct {
	refused:       bool, // an address wasn't public
	allow_private: bool,
}

// open_socket is the CURLOPT_OPENSOCKETFUNCTION: curl calls it with each address
// it is about to connect to, once the name is resolved.
@(private = "file")
open_socket :: proc "c" (user: rawptr, purpose: c.int, a: ^curl.Sockaddr) -> curl.Socket {
	context = runtime.default_context()
	state := (^Icon_Socket)(user)
	sa := ([^]u8)(&a.addr)[:a.addrlen]
	if !state.allow_private && !webpush.address_public(a.family, sa) {
		state.refused = true
		return curl.SOCKET_BAD
	}
	return curl.socket(a.family, a.socktype, a.protocol)
}

@(private = "file")
Icon_Sink :: struct {
	ctx:  runtime.Context,
	data: ^[dynamic]u8,
	full: bool, // it was longer than ICON_MAX_SIZE
}

@(private = "file")
collect :: proc "c" (data: [^]u8, size, count: uint, user: rawptr) -> uint {
	sink := (^Icon_Sink)(user)
	context = sink.ctx
	n := int(size * count)
	if len(sink.data) + n > ICON_MAX_SIZE {
		sink.full = true
		return 0 // curl then gives up
	}
	append(sink.data, ..data[:n])
	return uint(n)
}

// icon_fetch gets what is at `url`, which has to be a web address. `why` says
// what went wrong, if something did. The data is allocated with the temp allocator.
icon_fetch :: proc(
	lib: ^curl.Lib,
	h: curl.Handle,
	url: string,
	options: Icon_Options,
) -> (
	data: []u8,
	why: string,
) {
	if !strings.has_prefix(url, "http://") && !strings.has_prefix(url, "https://") {
		return nil, "not a web address"
	}
	tc :: proc(s: string) -> cstring {
		return strings.clone_to_cstring(s, context.temp_allocator)
	}
	lib.easy_reset(h)
	errors: [curl.ERROR_SIZE]u8
	body := make([dynamic]u8, context.temp_allocator)
	sink := Icon_Sink{context, &body, false}
	socket := Icon_Socket {
		allow_private = options.allow_private,
	}
	lib.easy_setopt(h, .Url, tc(url))
	lib.easy_setopt(h, .Connect_Timeout, c.long(ICON_CONNECT_TIMEOUT))
	lib.easy_setopt(h, .Timeout, c.long(ICON_TIMEOUT))
	lib.easy_setopt(h, .No_Signal, c.long(1))
	lib.easy_setopt(h, .Follow_Location, c.long(1))
	lib.easy_setopt(h, .Max_Redirs, c.long(ICON_REDIRECTS))
	lib.easy_setopt(h, .Protocols_Str, tc("http,https"))
	lib.easy_setopt(h, .Redir_Protocols_Str, tc("http,https"))
	lib.easy_setopt(h, .User_Agent, tc("yap-server import"))
	lib.easy_setopt(h, .Error_Buffer, raw_data(errors[:]))
	lib.easy_setopt(h, .Write_Function, collect)
	lib.easy_setopt(h, .Write_Data, &sink)
	lib.easy_setopt(h, .Open_Socket_Function, open_socket)
	lib.easy_setopt(h, .Open_Socket_Data, &socket)
	code := lib.easy_perform(h)
	switch {
	case socket.refused:
		return nil, "not on the public internet"
	case sink.full:
		return nil, "bigger than 2 MB"
	case code != 0:
		return nil, strings.clone(
			string(cstring(raw_data(errors[:]))) if errors[0] != 0 else string(lib.easy_strerror(code)),
			context.temp_allocator,
		)
	}
	status: c.long
	lib.easy_getinfo(h, curl.INFO_RESPONSE_CODE, &status)
	if status != 200 {
		return nil, fmt.tprintf("answered %d", status)
	}
	return body[:], ""
}

// import_icons fetches the pictures that the integrations pose with, once for
// each address, the most used first, and makes each a picture of the server's own.
// An address that doesn't give a picture is told of, and its posts have none.
import_icons :: proc(im: ^Importer, options := Icon_Options{}) -> bool {
	s := im.scan
	if len(s.icons) == 0 {
		return true
	}
	a := virtual.arena_allocator(&s.arena)
	lib: curl.Lib
	if !curl.load(&lib, "fetching the pictures of integrations") {
		for url in s.icons {
			mattermost.note(s, .Icon_Failed, fmt.tprintf("%s: libcurl is not available", url), a)
		}
		return true
	}
	h := lib.easy_init()
	if h == nil {
		return true
	}
	defer lib.easy_cleanup(h)

	urls := make([dynamic]string, 0, len(s.icons), context.temp_allocator)
	for url in s.icons {
		append(&urls, url)
	}
	slice.sort_by_with_data(urls[:], proc(x, y: string, data: rawptr) -> bool {
			counts := (^map[string]int)(data)
			if counts[x] != counts[y] {
				return counts[x] > counts[y]
			}
			return x < y
		}, &s.icons)

	started := time.tick_now()
	progress := progress_start("fetching pictures")
	done := 0
	for url, i in urls {
		progress_update(&progress, i64(i), i64(len(urls)))
		if i >= ICONS_MOST || time.tick_diff(started, time.tick_now()) > ICONS_BUDGET {
			mattermost.note(
				s,
				.Icon_Failed,
				fmt.tprintf("%s: not tried, there are too many", url),
				a,
			)
			continue
		}
		stored, failed := import_icon(im, &lib, h, url, options)
		if failed {
			return false
		}
		if !stored {
			continue
		}
		done += 1
	}
	progress.done = i64(done)
	progress_finish(&progress)
	return true
}

// import_icon fetches one address and stores what is there as a picture, which
// import_icons records. `failed` is for the database, not for the address,
// whose trouble is only told of.
@(private = "file")
import_icon :: proc(
	im: ^Importer,
	lib: ^curl.Lib,
	h: curl.Handle,
	url: string,
	options: Icon_Options,
) -> (
	stored, failed: bool,
) {
	// What it needs is let go of at the end, and nothing from before is.
	temp := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp)
	s := im.scan
	a := virtual.arena_allocator(&s.arena)
	data, why := icon_fetch(lib, h, url, options)
	if why != "" {
		mattermost.note(s, .Icon_Failed, fmt.tprintf("%s: %s", url, why), a)
		return
	}
	jpeg, side, made := avatar.from_bytes(data, context.temp_allocator)
	if !made {
		mattermost.note(s, .Icon_Failed, fmt.tprintf("%s: not a picture", url), a)
		return
	}
	file := blob_path(im.blobs, blob_hash(jpeg), virtual.arena_allocator(&im.arena))
	existed := os.exists(file)
	blob, put := blob_put(im.blobs, .Avatar, jpeg, side, side)
	if !put {
		log.errorf("could not store the picture from %s", url)
		return false, true
	}
	if !existed {
		append(&im.written, file)
	}
	im.icons[strings.clone(url, virtual.arena_allocator(&im.arena))] = blob
	return true, false
}
