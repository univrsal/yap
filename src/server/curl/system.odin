#+build !windows
package curl

import "core:c"
import "core:dynlib"
import "core:log"
import "core:sys/posix"

// curl_socket_t, and the value curl takes as a failure to open one.
Socket :: posix.FD
SOCKET_BAD :: Socket(-1)
AF_INET6 :: c.int(posix.AF.INET6)

// socket opens a socket, as a CURLOPT_OPENSOCKETFUNCTION does.
socket :: proc "c" (family, socktype, protocol: c.int) -> Socket {
	return posix.socket(posix.AF(family), posix.Sock(socktype), posix.Protocol(protocol))
}

// The possible locations of the system's libcurl, with the most likely first.
@(private = "file")
LIBRARIES :: [?]string {
	"libcurl.so.4",
	"libcurl.so",
	"libcurl.4.dylib",
	"/usr/lib/libcurl.4.dylib",
	"libcurl.dylib",
}

// The number of procedures in the Lib table.
@(private = "file")
PROCS :: 11

// load_system loads the system's libcurl into the table.
load_system :: proc(c: ^Lib, what: string) -> bool {
	for path in LIBRARIES {
		count, ok := dynlib.initialize_symbols(c, path, "curl_")
		if !ok {
			continue
		}
		if count != PROCS {
			log.errorf(
				"%s is missing procedures that %s needs (%d of %d found)",
				path,
				what,
				count,
				PROCS,
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
