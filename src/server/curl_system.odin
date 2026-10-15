#+build !windows
package server

import "core:dynlib"
import "core:log"

// Where the system's libcurl may be, most likely first.
@(private = "file")
CURL_LIBRARIES :: [?]string {
	"libcurl.so.4",
	"libcurl.so",
	"libcurl.4.dylib",
	"/usr/lib/libcurl.4.dylib",
	"libcurl.dylib",
}

// How many procedures there are in Curl.
@(private = "file")
CURL_PROCS :: 11

// curl_load_system loads the system's libcurl into the table.
curl_load_system :: proc(c: ^Curl, what: string) -> bool {
	for path in CURL_LIBRARIES {
		count, ok := dynlib.initialize_symbols(c, path, "curl_")
		if !ok {
			continue
		}
		if count != CURL_PROCS {
			log.errorf(
				"%s lacks some of what %s needs (%d of %d found)",
				path,
				what,
				count,
				CURL_PROCS,
			)
			return false
		}
		return true
	}
	log.errorf("libcurl isn't installed, so there's no %s: install libcurl (curl) for it", what)
	return false
}
