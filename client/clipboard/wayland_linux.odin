package clipboard

import "base:runtime"
import "core:dynlib"
import log "../../common/wlog"
import "core:strings"
import "core:sys/linux"
import "core:time"

/*
Wayland: the clipboard (the "selection") reaches clients through a
wl_data_device, and only while they have keyboard focus, so we use GLFW's
own connection, whose window is the one focused. Our wl_data_device lives
next to GLFW's, on an event queue of our own: GLFW's event loop reads our
events off the socket and queues them, and we handle them when asked for
an image. The compositor tells every data device about the selection
when the window gains focus and when the selection changes; each offer
lists its MIME types first.

To read, we ask the offer to write one of its types into a pipe
(wl_data_offer.receive) and read the other end until the source closes it.

libwayland-client is loaded at runtime (GLFW has it loaded already when
running on Wayland). Requests go through wl_proxy_marshal_array_flags,
which is what the inline helpers in wayland-client-protocol.h call.

Tested on KWin. GLFW has a data device of its own (for text), so the
compositor makes two offers for the same clipboard; weston serves only
the newest one it made, which is GLFW's, and then hands us nothing. We
report that as "no image", so pasting text still works there.
*/

@(private = "file")
Argument :: struct #raw_union {
	i: i32,
	u: u32,
	s: cstring,
	o: rawptr,
	n: u32,
	a: rawptr,
	h: i32,
}

@(private = "file")
MARSHAL_FLAG_DESTROY :: 1

// Opcodes from wayland.xml.
@(private = "file")
DISPLAY_GET_REGISTRY :: 1
@(private = "file")
REGISTRY_BIND :: 0
@(private = "file")
DATA_DEVICE_MANAGER_GET_DATA_DEVICE :: 1
@(private = "file")
DATA_DEVICE_RELEASE :: 2 // since version 2
@(private = "file")
DATA_OFFER_RECEIVE :: 1
@(private = "file")
DATA_OFFER_DESTROY :: 2

@(private = "file")
Symbols :: struct {
	__handle:                       dynlib.Library,
	display_create_queue:           proc "c" (display: rawptr) -> rawptr,
	event_queue_destroy:            proc "c" (queue: rawptr),
	display_roundtrip_queue:        proc "c" (display, queue: rawptr) -> i32,
	display_dispatch_queue_pending: proc "c" (display, queue: rawptr) -> i32,
	display_flush:                  proc "c" (display: rawptr) -> i32,
	proxy_create_wrapper:           proc "c" (proxy: rawptr) -> rawptr,
	proxy_wrapper_destroy:          proc "c" (wrapper: rawptr),
	proxy_set_queue:                proc "c" (proxy, queue: rawptr),
	proxy_marshal_array_flags:      proc "c" (
		proxy: rawptr,
		opcode: u32,
		interface: rawptr,
		version: u32,
		flags: u32,
		args: [^]Argument,
	) -> rawptr,
	proxy_add_listener:             proc "c" (proxy: rawptr, listener: rawptr, data: rawptr) -> i32,
	proxy_get_version:              proc "c" (proxy: rawptr) -> u32,
	proxy_destroy:                  proc "c" (proxy: rawptr),
	// Interface descriptions (data, not functions).
	registry_interface:             rawptr,
	seat_interface:                 rawptr,
	data_device_manager_interface:  rawptr,
	data_device_interface:          rawptr,
	data_offer_interface:           rawptr,
}

@(private = "file")
Offer :: struct {
	proxy: rawptr,
	mimes: [dynamic]string,
}

@(private = "file")
wl: struct {
	sym:       Symbols,
	loaded:    bool,
	display:   rawptr,
	queue:     rawptr,
	wrapper:   rawptr, // the display, on our queue
	registry:  rawptr,
	seat:      rawptr,
	manager:   rawptr,
	device:    rawptr,
	offers:    [dynamic]Offer,
	selection: rawptr, // the clipboard's current offer, or nil
	dnd:       rawptr, // a drag-and-drop offer, which we ignore
}

// Listeners are tables of C function pointers, in event order.
@(private = "file")
registry_listener := [2]rawptr{rawptr(registry_global), rawptr(registry_global_remove)}
@(private = "file")
data_device_listener := [6]rawptr {
	rawptr(device_data_offer),
	rawptr(device_enter),
	rawptr(device_leave),
	rawptr(device_motion),
	rawptr(device_drop),
	rawptr(device_selection),
}
@(private = "file")
data_offer_listener := [3]rawptr{rawptr(offer_offer), rawptr(offer_source_actions), rawptr(offer_action)}

// Our queue is only dispatched from wayland_init and wayland_read, so the
// handlers always run inside them, and take their context from there.
@(private = "file")
handler_context: runtime.Context

wayland_init :: proc(display: rawptr) -> bool {
	s := &wl.sym
	if _, ok := dynlib.initialize_symbols(s, "libwayland-client.so.0", "wl_"); !ok || !all_symbols(s) {
		log.debug("clipboard: couldn't load libwayland-client")
		return false
	}
	wl.loaded = true
	wl.display = display
	wl.queue = s.display_create_queue(display)
	wl.wrapper = s.proxy_create_wrapper(display)
	if wl.queue == nil || wl.wrapper == nil {
		wayland_destroy()
		return false
	}
	s.proxy_set_queue(wl.wrapper, wl.queue)

	handler_context = context

	args := [1]Argument{{o = nil}}
	wl.registry = s.proxy_marshal_array_flags(
		wl.wrapper,
		DISPLAY_GET_REGISTRY,
		s.registry_interface,
		s.proxy_get_version(wl.wrapper),
		0,
		&args[0],
	)
	if wl.registry == nil {
		wayland_destroy()
		return false
	}
	s.proxy_add_listener(wl.registry, &registry_listener, nil)
	// Globals arrive, and we bind the seat and data device manager.
	s.display_roundtrip_queue(display, wl.queue)

	if wl.seat == nil || wl.manager == nil {
		log.debug("clipboard: the compositor has no seat or data device manager")
		wayland_destroy()
		return false
	}
	dev_args := [2]Argument{{o = nil}, {o = wl.seat}}
	wl.device = s.proxy_marshal_array_flags(
		wl.manager,
		DATA_DEVICE_MANAGER_GET_DATA_DEVICE,
		s.data_device_interface,
		s.proxy_get_version(wl.manager),
		0,
		&dev_args[0],
	)
	if wl.device == nil {
		wayland_destroy()
		return false
	}
	s.proxy_add_listener(wl.device, &data_device_listener, nil)
	s.display_roundtrip_queue(display, wl.queue)
	log.debug("clipboard: using the Wayland data device")
	return true
}

wayland_destroy :: proc() {
	if !wl.loaded {
		return
	}
	s := &wl.sym
	for len(wl.offers) > 0 {
		destroy_offer(wl.offers[0].proxy)
	}
	delete(wl.offers)
	if wl.device != nil {
		if s.proxy_get_version(wl.device) >= 2 {
			s.proxy_marshal_array_flags(wl.device, DATA_DEVICE_RELEASE, nil, s.proxy_get_version(wl.device), MARSHAL_FLAG_DESTROY, nil)
		} else {
			s.proxy_destroy(wl.device)
		}
	}
	// The seat and manager have no destructor request in the versions we
	// bind; destroying the proxies only frees them on our side.
	for p in ([]rawptr{wl.manager, wl.seat, wl.registry}) {
		if p != nil {
			s.proxy_destroy(p)
		}
	}
	if wl.wrapper != nil {
		s.proxy_wrapper_destroy(wl.wrapper)
	}
	if wl.display != nil {
		s.display_flush(wl.display)
	}
	if wl.queue != nil {
		s.event_queue_destroy(wl.queue)
	}
	dynlib.unload_library(s.__handle)
	wl = {}
}

wayland_read :: proc(allocator := context.allocator) -> (data: []u8, mime: string, err: Error) {
	s := &wl.sym
	handler_context = context
	// Handle whatever GLFW's loop has queued for us, then make sure
	// nothing is still on its way.
	if s.display_dispatch_queue_pending(wl.display, wl.queue) < 0 ||
	   s.display_roundtrip_queue(wl.display, wl.queue) < 0 {
		return nil, "", .Unavailable
	}

	offer := find_offer(wl.selection)
	if offer == nil {
		return nil, "", .No_Image
	}
	ok: bool
	if mime, ok = pick_mime(offer.mimes[:]); !ok {
		log.debugf("clipboard: no image among %v", offer.mimes)
		return nil, "", .No_Image
	}

	fds: [2]linux.Fd
	if linux.pipe2(&fds, {.CLOEXEC}) != .NONE {
		return nil, "", .Unavailable
	}
	mime_c := strings.clone_to_cstring(mime, context.temp_allocator)
	args := [2]Argument{{s = mime_c}, {h = i32(fds[1])}}
	// libwayland sends a duplicate of the fd, so ours can go right away;
	// the read end sees EOF once the source closes its copy.
	s.proxy_marshal_array_flags(offer.proxy, DATA_OFFER_RECEIVE, nil, s.proxy_get_version(offer.proxy), 0, &args[0])
	linux.close(fds[1])
	s.display_flush(wl.display)

	data, err = read_all(fds[0], time.tick_add(time.tick_now(), READ_TIMEOUT_MS * time.Millisecond), allocator)
	if err == .None && len(data) == 0 {
		// Nothing came back: some compositors (weston) only serve the
		// newest offer they made the client, which is GLFW's, not ours.
		log.debug("clipboard: the compositor didn't serve our offer")
		delete(data, allocator)
		return nil, mime, .No_Image
	}
	return data, mime, err
}

@(private = "file")
all_symbols :: proc(s: ^Symbols) -> bool {
	return(
		s.display_create_queue != nil &&
		s.event_queue_destroy != nil &&
		s.display_roundtrip_queue != nil &&
		s.display_dispatch_queue_pending != nil &&
		s.display_flush != nil &&
		s.proxy_create_wrapper != nil &&
		s.proxy_wrapper_destroy != nil &&
		s.proxy_set_queue != nil &&
		s.proxy_marshal_array_flags != nil &&
		s.proxy_add_listener != nil &&
		s.proxy_get_version != nil &&
		s.proxy_destroy != nil &&
		s.registry_interface != nil &&
		s.seat_interface != nil &&
		s.data_device_manager_interface != nil &&
		s.data_device_interface != nil &&
		s.data_offer_interface != nil \
	)
}

@(private = "file")
find_offer :: proc(proxy: rawptr) -> ^Offer {
	if proxy == nil {
		return nil
	}
	for &o in wl.offers {
		if o.proxy == proxy {
			return &o
		}
	}
	return nil
}

@(private = "file")
destroy_offer :: proc(proxy: rawptr) {
	if proxy == nil {
		return
	}
	for o, i in wl.offers {
		if o.proxy == proxy {
			for m in o.mimes {
				delete(m)
			}
			delete(o.mimes)
			unordered_remove(&wl.offers, i)
			break
		}
	}
	s := &wl.sym
	s.proxy_marshal_array_flags(proxy, DATA_OFFER_DESTROY, nil, s.proxy_get_version(proxy), MARSHAL_FLAG_DESTROY, nil)
	if wl.selection == proxy {
		wl.selection = nil
	}
	if wl.dnd == proxy {
		wl.dnd = nil
	}
}

@(private = "file")
bind :: proc(name: u32, interface: rawptr, interface_name: cstring, version: u32) -> rawptr {
	s := &wl.sym
	args := [4]Argument{{u = name}, {s = interface_name}, {u = version}, {o = nil}}
	return s.proxy_marshal_array_flags(wl.registry, REGISTRY_BIND, interface, version, 0, &args[0])
}

@(private = "file")
registry_global :: proc "c" (data, registry: rawptr, name: u32, interface: cstring, version: u32) {
	context = handler_context
	switch string(interface) {
	case "wl_seat":
		// The first seat; desktops practically always have just one.
		if wl.seat == nil {
			wl.seat = bind(name, wl.sym.seat_interface, "wl_seat", 1)
		}
	case "wl_data_device_manager":
		if wl.manager == nil {
			wl.manager = bind(name, wl.sym.data_device_manager_interface, "wl_data_device_manager", min(version, 3))
		}
	}
}

@(private = "file")
registry_global_remove :: proc "c" (data, registry: rawptr, name: u32) {}

@(private = "file")
device_data_offer :: proc "c" (data, device, offer: rawptr) {
	context = handler_context
	append(&wl.offers, Offer{proxy = offer})
	wl.sym.proxy_add_listener(offer, &data_offer_listener, nil)
}

@(private = "file")
device_enter :: proc "c" (data, device: rawptr, serial: u32, surface: rawptr, x, y: i32, offer: rawptr) {
	context = handler_context
	wl.dnd = offer
}

@(private = "file")
device_leave :: proc "c" (data, device: rawptr) {
	context = handler_context
	if wl.dnd != nil && wl.dnd != wl.selection {
		destroy_offer(wl.dnd)
	}
	wl.dnd = nil
}

@(private = "file")
device_motion :: proc "c" (data, device: rawptr, time: u32, x, y: i32) {}

@(private = "file")
device_drop :: proc "c" (data, device: rawptr) {}

@(private = "file")
device_selection :: proc "c" (data, device, offer: rawptr) {
	context = handler_context
	if wl.selection != nil && wl.selection != offer {
		destroy_offer(wl.selection)
	}
	wl.selection = offer
	if o := find_offer(offer); o != nil {
		log.debugf("clipboard: new selection offering %v", o.mimes[:])
	}
}

@(private = "file")
offer_offer :: proc "c" (data, offer: rawptr, mime: cstring) {
	context = handler_context
	if o := find_offer(offer); o != nil {
		append(&o.mimes, strings.clone_from_cstring(mime))
	}
}

@(private = "file")
offer_source_actions :: proc "c" (data, offer: rawptr, actions: u32) {}

@(private = "file")
offer_action :: proc "c" (data, offer: rawptr, action: u32) {}
