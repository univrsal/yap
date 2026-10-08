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
CURL_PROCS :: 10

// curl_load_system loads the system's libcurl into the table.
curl_load_system :: proc(c: ^Curl) -> bool {
	for path in CURL_LIBRARIES {
		count, ok := dynlib.initialize_symbols(c, path, "curl_")
		if !ok {
			continue
		}
		if count != CURL_PROCS {
			log.errorf(
				"%s lacks some of what email needs (%d of %d found)",
				path,
				count,
				CURL_PROCS,
			)
			return false
		}
		return true
	}
	log.error("libcurl isn't installed, so there's no email: install libcurl (curl) for it")
	return false
}
