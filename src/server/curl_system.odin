#+build !windows
package server

import "core:c"
import "core:dynlib"
import "core:log"
import "core:sys/posix"

// curl_socket_t, and the value curl takes as a failure to open one.
Curl_Socket :: posix.FD
CURL_SOCKET_BAD :: Curl_Socket(-1)
AF_INET6 :: c.int(posix.AF.INET6)

// curl_socket opens a socket, as a CURLOPT_OPENSOCKETFUNCTION does.
curl_socket :: proc "c" (family, socktype, protocol: c.int) -> Curl_Socket {
	return posix.socket(posix.AF(family), posix.Sock(socktype), posix.Protocol(protocol))
}

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
