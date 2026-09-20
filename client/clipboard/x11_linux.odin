package clipboard

import "core:c"
import "core:dynlib"
import "core:log"
import "core:sys/linux"
import "core:time"

/*
X11: we ask the owner of the CLIPBOARD selection to convert it into a
property on a hidden window of our own, over a connection of our own
(so nothing interferes with GLFW's). First the TARGETS it offers, then
the image type we prefer. Large data comes in INCR mode: the owner
writes it in chunks, each after we delete the previous one, and ends
with an empty chunk.

libX11 is loaded at runtime (GLFW has it loaded already when running on
X11).
*/

@(private = "file")
Display :: rawptr
@(private = "file")
Window :: c.ulong
@(private = "file")
Atom :: c.ulong

// The parts of XEvent we look at; the union is 24 longs.
@(private = "file")
Event :: struct #raw_union {
	type:      c.int,
	selection: Selection_Event,
	property:  Property_Event,
	pad:       [24]c.long,
}

@(private = "file")
Selection_Event :: struct {
	type:       c.int,
	serial:     c.ulong,
	send_event: b32,
	display:    Display,
	requestor:  Window,
	selection:  Atom,
	target:     Atom,
	property:   Atom,
	time:       c.ulong,
}

@(private = "file")
Property_Event :: struct {
	type:       c.int,
	serial:     c.ulong,
	send_event: b32,
	display:    Display,
	window:     Window,
	atom:       Atom,
	time:       c.ulong,
	state:      c.int,
}

@(private = "file")
PROPERTY_NOTIFY :: 28
@(private = "file")
SELECTION_NOTIFY :: 31
@(private = "file")
PROPERTY_NEW_VALUE :: 0
@(private = "file")
PROPERTY_CHANGE_MASK :: 1 << 22
@(private = "file")
ANY_PROPERTY_TYPE :: 0
@(private = "file")
CURRENT_TIME :: 0

@(private = "file")
Symbols :: struct {
	__handle:               dynlib.Library,
	XOpenDisplay:           proc "c" (name: cstring) -> Display,
	XCloseDisplay:          proc "c" (d: Display) -> c.int,
	XDefaultRootWindow:     proc "c" (d: Display) -> Window,
	XCreateSimpleWindow:    proc "c" (d: Display, parent: Window, x, y: c.int, w, h, border_width: c.uint, border, background: c.ulong) -> Window,
	XDestroyWindow:         proc "c" (d: Display, w: Window) -> c.int,
	XSelectInput:           proc "c" (d: Display, w: Window, mask: c.long) -> c.int,
	XInternAtom:            proc "c" (d: Display, name: cstring, only_if_exists: b32) -> Atom,
	XGetSelectionOwner:     proc "c" (d: Display, selection: Atom) -> Window,
	XConvertSelection:      proc "c" (d: Display, selection, target, property: Atom, requestor: Window, time: c.ulong) -> c.int,
	XGetWindowProperty:     proc "c" (
		d: Display,
		w: Window,
		property: Atom,
		offset, length: c.long,
		delete: b32,
		req_type: Atom,
		actual_type: ^Atom,
		actual_format: ^c.int,
		nitems, bytes_after: ^c.ulong,
		prop: ^[^]u8,
	) -> c.int,
	XDeleteProperty:        proc "c" (d: Display, w: Window, property: Atom) -> c.int,
	XFree:                  proc "c" (data: rawptr) -> c.int,
	XFlush:                 proc "c" (d: Display) -> c.int,
	XConnectionNumber:      proc "c" (d: Display) -> c.int,
	XCheckTypedWindowEvent: proc "c" (d: Display, w: Window, type: c.int, event: ^Event) -> b32,
}

@(private = "file")
x: struct {
	sym:       Symbols,
	display:   Display,
	window:    Window,
	clipboard: Atom,
	targets:   Atom,
	incr:      Atom,
	property:  Atom, // where the owner puts the data for us
}

x11_init :: proc() -> bool {
	s := &x.sym
	if _, ok := dynlib.initialize_symbols(s, "libX11.so.6"); !ok || !x11_symbols_ok(s) {
		log.debug("clipboard: couldn't load libX11")
		return false
	}
	x.display = s.XOpenDisplay(nil)
	if x.display == nil {
		dynlib.unload_library(s.__handle)
		x = {}
		return false
	}
	x.window = s.XCreateSimpleWindow(x.display, s.XDefaultRootWindow(x.display), 0, 0, 1, 1, 0, 0, 0)
	s.XSelectInput(x.display, x.window, PROPERTY_CHANGE_MASK)
	x.clipboard = s.XInternAtom(x.display, "CLIPBOARD", false)
	x.targets = s.XInternAtom(x.display, "TARGETS", false)
	x.incr = s.XInternAtom(x.display, "INCR", false)
	x.property = s.XInternAtom(x.display, "YAP_CLIPBOARD", false)
	s.XFlush(x.display)
	log.debug("clipboard: using X11")
	return true
}

x11_destroy :: proc() {
	s := &x.sym
	if x.display != nil {
		s.XDestroyWindow(x.display, x.window)
		s.XCloseDisplay(x.display)
	}
	if s.__handle != nil {
		dynlib.unload_library(s.__handle)
	}
	x = {}
}

x11_read :: proc(allocator := context.allocator) -> (data: []u8, mime: string, err: Error) {
	s := &x.sym
	if s.XGetSelectionOwner(x.display, x.clipboard) == 0 {
		return nil, "", .No_Image
	}
	deadline := time.tick_add(time.tick_now(), READ_TIMEOUT_MS * time.Millisecond)

	// Which image types are on offer?
	targets := convert(x.targets, deadline, context.temp_allocator) or_return
	offered := make([dynamic]string, context.temp_allocator)
	atoms := ([^]Atom)(raw_data(targets))[:len(targets) / size_of(Atom)]
	for want in MIME_TYPES {
		atom := s.XInternAtom(x.display, cstring_of(want), true)
		for a in atoms {
			if atom != 0 && a == atom {
				append(&offered, want)
			}
		}
	}
	ok: bool
	if mime, ok = pick_mime(offered[:]); !ok {
		return nil, "", .No_Image
	}

	data = convert(s.XInternAtom(x.display, cstring_of(mime), false), deadline, allocator) or_return
	return data, mime, .None
}

// convert asks the owner for the selection as `target` and returns the
// bytes it sends (for 32-bit formats like TARGETS: as C longs).
@(private = "file")
convert :: proc(target: Atom, deadline: time.Tick, allocator := context.allocator) -> (data: []u8, err: Error) {
	s := &x.sym
	s.XDeleteProperty(x.display, x.window, x.property)
	s.XConvertSelection(x.display, x.clipboard, target, x.property, x.window, CURRENT_TIME)
	s.XFlush(x.display)

	ev: Event
	wait_event(SELECTION_NOTIFY, &ev, deadline) or_return
	if ev.selection.property == 0 {
		return nil, .No_Image // the owner refused
	}

	first, type := read_property(allocator) or_return
	if type != x.incr {
		return first, .None
	}

	// INCR: reading (and deleting) the property started the transfer.
	delete(first, allocator)
	buf := make([dynamic]u8, allocator)
	for {
		wait_event(PROPERTY_NOTIFY, &ev, deadline, want_new_value = true) or_return
		chunk, chunk_type, chunk_err := read_property()
		defer delete(chunk)
		if chunk_err != .None {
			delete(buf)
			return nil, chunk_err
		}
		if chunk_type == 0 {
			// No such property: a stale event from before (e.g. for the
			// INCR property itself), not a chunk.
			continue
		}
		if len(chunk) == 0 {
			return buf[:], .None
		}
		if len(buf) + len(chunk) > MAX_DATA_SIZE {
			delete(buf)
			return nil, .Too_Large
		}
		append(&buf, ..chunk)
	}
}

// read_property reads and deletes our property.
@(private = "file")
read_property :: proc(allocator := context.allocator) -> (data: []u8, type: Atom, err: Error) {
	s := &x.sym
	format: c.int
	nitems, bytes_after: c.ulong
	prop: [^]u8
	// The length is in 32-bit units; this is "everything".
	if s.XGetWindowProperty(x.display, x.window, x.property, 0, c.long(max(i32) / 4), true, ANY_PROPERTY_TYPE, &type, &format, &nitems, &bytes_after, &prop) != 0 {
		return nil, 0, .Unavailable
	}
	defer if prop != nil {
		s.XFree(prop)
	}
	// Xlib hands 32-bit items over as C longs.
	item_size: int
	switch format {
	case 8:
		item_size = 1
	case 16:
		item_size = size_of(c.short)
	case 32:
		item_size = size_of(c.long)
	}
	n := int(nitems) * item_size
	if n > MAX_DATA_SIZE || bytes_after > 0 {
		return nil, type, .Too_Large
	}
	data = make([]u8, n, allocator)
	if n > 0 {
		copy(data, prop[:n])
	}
	return data, type, .None
}

// wait_event waits for an event of `type` on our window (for property
// events: a new value of our property).
@(private = "file")
wait_event :: proc(type: c.int, ev: ^Event, deadline: time.Tick, want_new_value := false) -> Error {
	s := &x.sym
	fd := linux.Fd(s.XConnectionNumber(x.display))
	for {
		for s.XCheckTypedWindowEvent(x.display, x.window, type, ev) {
			if type != PROPERTY_NOTIFY ||
			   (ev.property.atom == x.property && (!want_new_value || ev.property.state == PROPERTY_NEW_VALUE)) {
				return .None
			}
		}
		remaining := time.tick_diff(time.tick_now(), deadline)
		if remaining <= 0 {
			return .Timeout
		}
		fds := [1]linux.Poll_Fd{{fd = fd, events = {.IN}}}
		linux.poll(fds[:], min(i32(time.duration_milliseconds(remaining)) + 1, 50))
	}
}

@(private = "file")
cstring_of :: proc(s: string) -> cstring {
	b := make([]u8, len(s) + 1, context.temp_allocator)
	copy(b, s)
	return cstring(raw_data(b))
}

@(private = "file")
x11_symbols_ok :: proc(s: ^Symbols) -> bool {
	return(
		s.XOpenDisplay != nil &&
		s.XCloseDisplay != nil &&
		s.XDefaultRootWindow != nil &&
		s.XCreateSimpleWindow != nil &&
		s.XDestroyWindow != nil &&
		s.XSelectInput != nil &&
		s.XInternAtom != nil &&
		s.XGetSelectionOwner != nil &&
		s.XConvertSelection != nil &&
		s.XGetWindowProperty != nil &&
		s.XDeleteProperty != nil &&
		s.XFree != nil &&
		s.XFlush != nil &&
		s.XConnectionNumber != nil &&
		s.XCheckTypedWindowEvent != nil \
	)
}
