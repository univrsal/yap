#+build windows
package curl

import "core:c"
import "core:sys/windows"
import curl "vendor:curl"

// curl_socket_t, and the value curl takes as a failure to open one.
Socket :: windows.SOCKET
SOCKET_BAD :: windows.INVALID_SOCKET
AF_INET6 :: c.int(windows.AF_INET6)

// socket opens a socket, as a CURLOPT_OPENSOCKETFUNCTION does. Winsock
// was started by curl_global_init.
socket :: proc "c" (family, socktype, protocol: c.int) -> Socket {
	return windows.socket(family, socktype, protocol)
}

// load_system uses the libcurl from Odin's vendor directory, which is
// linked in statically because Windows has no system libcurl.
load_system :: proc(c: ^Lib, what: string) -> bool {
	c.version = auto_cast curl.version
	c.global_init = auto_cast curl.global_init
	c.easy_init = auto_cast curl.easy_init
	c.easy_cleanup = auto_cast curl.easy_cleanup
	c.easy_reset = auto_cast curl.easy_reset
	c.easy_setopt = auto_cast curl.easy_setopt
	c.easy_perform = auto_cast curl.easy_perform
	c.easy_getinfo = auto_cast curl.easy_getinfo
	c.easy_strerror = auto_cast curl.easy_strerror
	c.slist_append = auto_cast curl.slist_append
	c.slist_free_all = auto_cast curl.slist_free_all
	return true
}
