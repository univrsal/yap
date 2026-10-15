#+build !windows
package server

import "core:dynlib"
import "core:log"

// The possible locations of the system's libcurl, with the most likely first.
@(private = "file")
CURL_LIBRARIES :: [?]string {
	"libcurl.so.4",
	"libcurl.so",
	"libcurl.4.dylib",
	"/usr/lib/libcurl.4.dylib",
	"libcurl.dylib",
}

// The number of procedures in the Curl table.
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
				"%s is missing procedures that %s needs (%d of %d found)",
				path,
				what,
				count,
				CURL_PROCS,
			)
			return false
		}
		return true
	}
	log.errorf(
		"libcurl isn't installed, so %s is unavailable (install libcurl to enable it)",
		what,
	)
	return false
}
