#+build windows
package sockbuf

import "core:net"
import win "core:sys/windows"

@(private)
_set_buffer_size :: proc(sock: net.Socket, receive: bool, bytes: int) -> bool {
	value := win.c_int(min(bytes, int(max(i32))))
	opt := win.SO_RCVBUF if receive else win.SO_SNDBUF
	return win.setsockopt(win.SOCKET(sock), win.SOL_SOCKET, opt, &value, size_of(value)) == 0
}
