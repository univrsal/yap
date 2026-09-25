package clipboard

import log "../../common/wlog"
import "core:sys/linux"
import "core:time"

@(private = "file")
Backend :: enum {
	None,
	Wayland,
	X11,
}

@(private = "file")
backend: Backend

_init :: proc(wayland_display: rawptr) -> bool {
	switch {
	case wayland_display != nil:
		if wayland_init(wayland_display) {
			backend = .Wayland
		}
	case:
		if x11_init() {
			backend = .X11
		}
	}
	if backend == .None {
		log.warn("clipboard: images can't be pasted (no Wayland or X11 clipboard access)")
	}
	return backend != .None
}

_destroy :: proc() {
	switch backend {
	case .Wayland:
		wayland_destroy()
	case .X11:
		x11_destroy()
	case .None:
	}
	backend = .None
}

_read_encoded :: proc(allocator := context.allocator) -> (data: []u8, mime: string, err: Error) {
	switch backend {
	case .Wayland:
		return wayland_read(allocator)
	case .X11:
		return x11_read(allocator)
	case .None:
	}
	return nil, "", .Unavailable
}

// read_all reads `fd` to its end, giving up at `deadline` or past
// MAX_DATA_SIZE. It closes `fd`.
read_all :: proc(fd: linux.Fd, deadline: time.Tick, allocator := context.allocator) -> (data: []u8, err: Error) {
	defer linux.close(fd)
	buf := make([dynamic]u8, 0, 64 * 1024, allocator)
	chunk: [64 * 1024]u8
	for {
		remaining := time.tick_diff(time.tick_now(), deadline)
		if remaining <= 0 {
			delete(buf)
			return nil, .Timeout
		}
		fds := [1]linux.Poll_Fd{{fd = fd, events = {.IN}}}
		n, poll_err := linux.poll(fds[:], i32(time.duration_milliseconds(remaining)) + 1)
		if poll_err == .EINTR || n == 0 {
			continue
		}
		if poll_err != .NONE {
			delete(buf)
			return nil, .Unavailable
		}
		got, read_err := linux.read(fd, chunk[:])
		switch {
		case read_err == .EINTR || read_err == .EAGAIN:
			continue
		case read_err != .NONE:
			delete(buf)
			return nil, .Unavailable
		case got == 0:
			return buf[:], .None
		case len(buf) + got > MAX_DATA_SIZE:
			delete(buf)
			return nil, .Too_Large
		}
		append(&buf, ..chunk[:got])
	}
}
