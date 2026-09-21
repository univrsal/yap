/*
The page's side of the web build: the few things the client asks of
the browser, written as the JavaScript they are, and the entry point
that hands the client its frames.

- Storage: the key, settings and known servers live in localStorage
  under the names the client gives them (common/store_web.odin).
- WebSocket: one socket to the relay, carrying one packet per binary
  message; arriving messages wait in a queue until the client's network
  loop takes them (client/transport_web.odin).
- A few small questions about the page: where it was served from, what
  the address said, the local time's offset from UTC.

main() starts the client and then lets the browser drive it: web_frame
runs once for every frame the browser draws.
*/
#include <emscripten.h>
#include <stdio.h>

extern int web_start(void);
extern void web_frame(void);

/* ---- localStorage ---- */

EM_JS(int, yap_store_exists, (const char *name), {
	try {
		return localStorage.getItem(UTF8ToString(name)) !== null ? 1 : 0;
	} catch (e) {
		return 0;
	}
});

EM_JS(int, yap_store_read, (const char *name, char *buf, int buf_size), {
	let value;
	try {
		value = localStorage.getItem(UTF8ToString(name));
	} catch (e) {
		return -1;
	}
	if (value === null) return -1;
	const size = lengthBytesUTF8(value);
	if (size + 1 > buf_size) return -1;
	stringToUTF8(value, buf, buf_size);
	return size;
});

EM_JS(int, yap_store_write, (const char *name, const char *data, int size), {
	try {
		const text = new TextDecoder().decode(HEAPU8.subarray(data, data + size));
		localStorage.setItem(UTF8ToString(name), text);
		return 1;
	} catch (e) {
		console.error("yap: could not store", UTF8ToString(name), e);
		return 0;
	}
});

/* ---- the WebSocket to the relay ---- */

EM_JS(int, yap_ws_open, (const char *url), {
	if (!Module.yapWs) Module.yapWs = {socket: null, queue: [], state: -1};
	const w = Module.yapWs;
	if (w.socket) {
		w.socket.onopen = w.socket.onmessage = w.socket.onclose = w.socket.onerror = null;
		w.socket.close();
	}
	w.queue = [];
	w.state = 0;
	try {
		w.socket = new WebSocket(UTF8ToString(url));
	} catch (e) {
		console.error("yap:", e);
		w.state = -1;
		return 0;
	}
	w.socket.binaryType = "arraybuffer";
	w.socket.onopen = () => { w.state = 1; };
	w.socket.onmessage = (event) => {
		if (event.data instanceof ArrayBuffer) w.queue.push(new Uint8Array(event.data));
	};
	w.socket.onclose = w.socket.onerror = () => { w.state = -1; };
	return 1;
});

EM_JS(void, yap_ws_close, (), {
	const w = Module.yapWs;
	if (w && w.socket) {
		w.socket.onopen = w.socket.onmessage = w.socket.onclose = w.socket.onerror = null;
		w.socket.close();
		w.socket = null;
		w.state = -1;
		w.queue = [];
	}
});

EM_JS(int, yap_ws_state, (), {
	const w = Module.yapWs;
	return w ? w.state : -1;
});

EM_JS(int, yap_ws_send, (const unsigned char *data, int size), {
	const w = Module.yapWs;
	if (!w || w.state !== 1) return 0;
	// A copy: the heap view is only good until the next allocation.
	w.socket.send(HEAPU8.slice(data, data + size));
	return 1;
});

EM_JS(int, yap_ws_recv, (unsigned char *buf, int buf_size), {
	const w = Module.yapWs;
	if (!w || w.queue.length === 0) return -1;
	const message = w.queue.shift();
	// Too big for a packet: not one of ours, so it's dropped.
	if (message.length > buf_size) return -1;
	HEAPU8.set(message, buf);
	return message.length;
});

EM_JS(int, yap_ws_origin, (char *buf, int buf_size), {
	const origin = (location.protocol === "https:" ? "wss://" : "ws://") + location.host;
	if (lengthBytesUTF8(origin) + 1 > buf_size) return 0;
	stringToUTF8(origin, buf, buf_size);
	return lengthBytesUTF8(origin);
});

/* ---- the page ---- */

EM_JS(int, yap_query_param, (const char *name, char *buf, int buf_size), {
	const value = new URLSearchParams(location.search).get(UTF8ToString(name));
	if (!value || lengthBytesUTF8(value) + 1 > buf_size) return 0;
	stringToUTF8(value, buf, buf_size);
	return lengthBytesUTF8(value);
});

EM_JS(int, yap_open_url, (const char *url), {
	return window.open(UTF8ToString(url), "_blank", "noopener") ? 1 : 0;
});

EM_JS(int, yap_utc_offset_minutes, (), {
	return -new Date().getTimezoneOffset();
});

/* Puts a phone's keyboard away: the hidden field that brought it up
   (web/touch.js) lets go of the focus. */
EM_JS(void, yap_keyboard_hide, (), {
	const field = document.getElementById("yap-keyboard");
	if (field && document.activeElement === field) field.blur();
});

int main(void) {
	if (!web_start()) {
		printf("yap: the client could not start\n");
		return 1;
	}
	emscripten_set_main_loop(web_frame, 0, 1);
	return 0;
}
