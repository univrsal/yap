/*
The page's side of the web build: the few things the client asks of
the browser, written as the JavaScript they are, and the entry point
that hands the client its frames.

- Storage: the key, settings and known servers live in localStorage
  under the names the client gives them (src/common/store_web.odin).
- WebSocket: one socket to the relay, carrying one packet per binary
  message; arriving messages wait in a queue until the client's network
  loop takes them (src/client/transport_web.odin).
- Screen sharing: hooks into Module.yapVideo, which does the capturing,
  encoding and decoding (src/client/video/web.odin).
- A few small questions about the page: where it was served from, what
  the address said, the local time's offset from UTC.

main() starts the client and then lets the browser drive it: web_frame
runs once for every frame the browser draws.
*/
#include <emscripten.h>
#include <malloc.h>
#include <stdio.h>

extern int web_start(void);
extern void web_frame(void);

/* ---- memory ---- */

/* What of malloc's memory is in use and what it keeps free, for the
   memory page (src/common/memtrack/process_web.odin): mallinfo returns
   its struct by value, which is simpler handed over as two numbers. */
void yap_malloc_stats(int *in_use, int *free_bytes) {
	struct mallinfo info = mallinfo();
	*in_use = info.uordblks;
	*free_bytes = info.fordblks;
}

/* ---- localStorage ---- */

// Whether the page has the focus and is on screen: a conversation is only
// read while it is.
EM_JS(int, yap_page_focused, (void), {
	return document.hasFocus() && !document.hidden ? 1 : 0;
});

/* The mouse cursor over the canvas, for a GLFW cursor shape
   (src/client/wglfw/wglfw_web.odin); 0, or one it doesn't know, is the
   default arrow. */
EM_JS(void, yap_set_cursor, (int shape), {
	const names = {
		0x36002: "text",
		0x36004: "pointer",
		0x36005: "ew-resize",
		0x36006: "ns-resize",
		0x36007: "nwse-resize",
		0x36008: "nesw-resize",
	};
	if (Module.canvas) Module.canvas.style.cursor = names[shape] || "";
});

// The tab's title, which says when something is unread.
EM_JS(void, yap_set_title, (const char *title), {
	document.title = UTF8ToString(title);
});

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

EM_JS(int, yap_store_remove, (const char *name), {
	try {
		localStorage.removeItem(UTF8ToString(name));
		return 1;
	} catch (e) {
		console.error("yap: could not remove", UTF8ToString(name), e);
		return 0;
	}
});

/* ---- the WebSockets to the relay ----
One per link of the connection (src/client/conn/bulk.odin), by slot: 0
for the main link, 1 for the bulk link, 2 for the media link. Each queues what arrives on it,
so the main link's messages never wait behind the bulk link's. */

EM_JS(int, yap_ws_open, (int slot, const char *url), {
	if (!Module.yapWs) Module.yapWs = [];
	if (!Module.yapWs[slot]) Module.yapWs[slot] = {socket: null, queue: [], head: 0, state: -1};
	const w = Module.yapWs[slot];
	if (w.socket) {
		w.socket.onopen = w.socket.onmessage = w.socket.onclose = w.socket.onerror = null;
		w.socket.close();
	}
	w.queue = [];
	w.head = 0;
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

EM_JS(void, yap_ws_close, (int slot), {
	const w = Module.yapWs && Module.yapWs[slot];
	if (w && w.socket) {
		w.socket.onopen = w.socket.onmessage = w.socket.onclose = w.socket.onerror = null;
		w.socket.close();
		w.socket = null;
		w.state = -1;
		w.queue = [];
		w.head = 0;
	}
});

EM_JS(int, yap_ws_state, (int slot), {
	const w = Module.yapWs && Module.yapWs[slot];
	return w ? w.state : -1;
});

EM_JS(int, yap_ws_send, (int slot, const unsigned char *data, int size), {
	const w = Module.yapWs && Module.yapWs[slot];
	if (!w || w.state !== 1) return 0;
	// A copy: the heap view is only good until the next allocation.
	w.socket.send(HEAPU8.slice(data, data + size));
	return 1;
});

EM_JS(int, yap_ws_recv, (int slot, unsigned char *buf, int buf_size), {
	const w = Module.yapWs && Module.yapWs[slot];
	if (!w || w.head === w.queue.length) return -1;
	// Taken from the front without shifting the array, which costs as
	// much as what's queued behind: a keyframe is a hundred and more.
	const message = w.queue[w.head++];
	if (w.head === w.queue.length) {
		w.queue = [];
		w.head = 0;
	}
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

EM_JS(int, yap_ws_buffered, (int slot), {
	const w = Module.yapWs && Module.yapWs[slot];
	return w && w.socket && w.state === 1 ? w.socket.bufferedAmount : 0;
});

EM_JS(int, yap_ws_pending, (int slot), {
	const w = Module.yapWs && Module.yapWs[slot];
	return w ? w.queue.length - w.head : 0;
});

/* ---- idle ----
The Idle Detection API (Chromium only): whether there's been input
anywhere on the computer, for being away by ourselves (src/client/idle).
It needs the page to have been allowed, which takes a click to ask for
(yap_idle_web_ask); the browser remembers the answer, so later pages
start it at once. Its shortest threshold is a minute. */

EM_JS(void, yap_idle_web_open, (int after_ms), {
	const s = (Module.yapIdle = { state: -1, permission: "none", controller: null });
	s.after = Math.max(after_ms, 60000);
	if (typeof IdleDetector !== "function" || !navigator.permissions) return;
	s.start = async () => {
		if (s.controller) return;
		const controller = new AbortController();
		try {
			const detector = new IdleDetector();
			detector.addEventListener("change", () => {
				s.state = detector.userState === "idle" ? 1 : 0;
			});
			await detector.start({ threshold: s.after, signal: controller.signal });
			s.controller = controller;
			s.state = detector.userState === "idle" ? 1 : 0;
		} catch (e) {
			console.warn("yap: no idle detection:", e);
		}
	};
	navigator.permissions.query({ name: "idle-detection" }).then((p) => {
		s.permission = p.state;
		p.onchange = () => {
			s.permission = p.state;
			if (p.state === "granted") s.start();
		};
		if (p.state === "granted") s.start();
	}, () => {});
});

EM_JS(int, yap_idle_web_check, (), {
	const s = Module.yapIdle;
	return s ? s.state : -1;
});

EM_JS(int, yap_idle_web_can_ask, (), {
	const s = Module.yapIdle;
	return s && s.permission === "prompt" ? 1 : 0;
});

EM_JS(void, yap_idle_web_ask, (), {
	const s = Module.yapIdle;
	if (!s || !s.start) return;
	IdleDetector.requestPermission().then((answer) => {
		s.permission = answer;
		if (answer === "granted") s.start();
	}, () => {});
});

EM_JS(void, yap_idle_web_close, (), {
	const s = Module.yapIdle;
	if (s && s.controller) s.controller.abort();
	Module.yapIdle = null;
});

/* ---- screen sharing and the camera ----

The capturing, encoding and decoding are the page's, in Module.yapVideo
if it has one; without it, nobody here shares or watches
(src/client/video/web.odin). Encoded frames wait there until the client
pulls them, one at a time, the way packets wait on the WebSocket. `stream` is
0 for the screen and 1 for the camera (proto.Video_Stream).
*/

EM_JS(int, yap_video_live, (int stream), {
	const v = Module.yapVideo;
	return v && v.live(stream) ? 1 : 0;
});

EM_JS(int, yap_video_next_size, (int stream), {
	const v = Module.yapVideo;
	return v ? v.nextSize(stream) : -1;
});

EM_JS(int, yap_video_pull, (int stream, unsigned char *buf, int buf_size, unsigned int *ts, int *key, int *codec), {
	const v = Module.yapVideo;
	const frame = v ? v.pull(stream) : null;
	if (!frame || frame.data.length > buf_size) return -1;
	HEAPU8.set(frame.data, buf);
	HEAPU32[ts >> 2] = frame.ts >>> 0;
	HEAP32[key >> 2] = frame.key ? 1 : 0;
	HEAP32[codec >> 2] = frame.codec;
	return frame.data.length;
});

/* Shared audio (the tab's or the system's, where the browser gives it):
   whether there is any, and up to `max` samples of it, interleaved stereo at
   48 kHz. Returns how many were copied. */
EM_JS(int, yap_video_audio_live, (), {
	const v = Module.yapVideo;
	return v && v.audioLive() ? 1 : 0;
});

EM_JS(int, yap_video_audio_pull, (float *buf, int max), {
	const v = Module.yapVideo;
	const samples = v ? v.pullAudio(max) : null;
	if (!samples) return 0;
	HEAPF32.set(samples, buf >> 2);
	return samples.length;
});

EM_JS(void, yap_video_request_key, (int stream), {
	const v = Module.yapVideo;
	if (v) v.requestKey(stream);
});

EM_JS(void, yap_video_show, (unsigned int sharer, int stream, const unsigned char *data, int size, unsigned int ts, int key, int codec), {
	const v = Module.yapVideo;
	// A copy: the heap view is only good until the next allocation.
	if (v) v.show(sharer, stream, HEAPU8.slice(data, data + size), ts, key !== 0, codec);
});

EM_JS(void, yap_video_end, (unsigned int sharer, int stream), {
	const v = Module.yapVideo;
	if (v) v.end(sharer, stream);
});

EM_JS(int, yap_video_take_error, (unsigned int sharer, int stream), {
	const v = Module.yapVideo;
	return v && v.takeError(sharer, stream) ? 1 : 0;
});

EM_JS(int, yap_video_can_share, (), {
	const v = Module.yapVideo;
	return v && v.canShare() ? 1 : 0;
});

EM_JS(int, yap_video_can_camera, (), {
	const v = Module.yapVideo;
	return v && v.canCamera() ? 1 : 0;
});

EM_JS(int, yap_video_can_watch, (), {
	const v = Module.yapVideo;
	return v && v.canWatch() ? 1 : 0;
});

EM_JS(int, yap_video_decodable, (), {
	const v = Module.yapVideo;
	return v ? v.decodable() : 0;
});

/* The page's encoders, best first: how many (-1 while they are being tried,
   which asking starts), and the name, label and whether it works of one. */
EM_JS(int, yap_video_encoder_count, (), {
	const v = Module.yapVideo;
	const list = v ? v.encoders() : [];
	return list ? list.length : -1;
});

EM_JS(int, yap_video_encoder_info, (int i, char *name, int name_size, char *label, int label_size, int *works), {
	const v = Module.yapVideo;
	const list = v ? v.encoders() : null;
	const e = list ? list[i] : null;
	if (!e) return 0;
	stringToUTF8(e.name, name, name_size);
	stringToUTF8(e.label, label, label_size);
	HEAP32[works >> 2] = e.works ? 1 : 0;
	return 1;
});

/* `encoder` is one of the page's encoders by name, or "" for the best that
   works. */
EM_JS(void, yap_video_share_start, (int fps, int kbit, int max_width, int max_height, const char *encoder), {
	const v = Module.yapVideo;
	if (v) v.start(fps, kbit, max_width, max_height, UTF8ToString(encoder));
});

/* Turns on the camera `device` (a deviceId, "" for the browser's choice). */
EM_JS(void, yap_video_camera_start, (int fps, int kbit, int max_width, int max_height, const char *device, const char *encoder), {
	const v = Module.yapVideo;
	if (v) v.startCamera(fps, kbit, max_width, max_height, UTF8ToString(device), UTF8ToString(encoder));
});

/* What a stream's viewers decode, as bits (1 << codec; 0 for any). */
EM_JS(void, yap_video_set_codecs, (int stream, int codecs), {
	const v = Module.yapVideo;
	if (v) v.setCodecs(stream, codecs);
});

/* Why a stream failed, into buf; "" if only the browser's console says. */
EM_JS(void, yap_video_why, (int stream, char *buf, int buf_size), {
	const v = Module.yapVideo;
	stringToUTF8(v ? v.why(stream) : "", buf, buf_size);
});

/* Has the camera go on at another size, frame rate or bitrate. */
EM_JS(void, yap_video_camera_configure, (int fps, int kbit, int max_width, int max_height), {
	const v = Module.yapVideo;
	if (v) v.configureCamera(fps, kbit, max_width, max_height);
});

/* Stops encoding the camera while nobody watches it (1), or goes on (0),
   from a keyframe. */
EM_JS(void, yap_video_camera_pause, (int paused), {
	const v = Module.yapVideo;
	if (v) v.pauseCamera(paused !== 0);
});

/* The settings' cameras: has the browser list them again (the answer comes
   later), how many there are as last listed, and the id and name of one
   ("" each until a camera has been allowed). */
EM_JS(void, yap_video_cameras_refresh, (), {
	const v = Module.yapVideo;
	if (v) v.refreshCameras();
});

EM_JS(int, yap_video_camera_count, (), {
	const v = Module.yapVideo;
	return v ? v.cameras().length : 0;
});

EM_JS(int, yap_video_camera_info, (int i, char *id, int id_size, char *name, int name_size), {
	const v = Module.yapVideo;
	const c = v ? v.cameras()[i] : null;
	if (!c) return 0;
	stringToUTF8(c.id, id, id_size);
	stringToUTF8(c.name, name, name_size);
	return 1;
});

/* The settings' preview of the camera `device` while ours is off: opened,
   but not sent; its frames come as our camera's (yap_video_upload with
   sharer 0). */
EM_JS(void, yap_video_camera_look, (const char *device, int max_width, int max_height), {
	const v = Module.yapVideo;
	if (v) v.startLook(UTF8ToString(device), max_width, max_height);
});

EM_JS(void, yap_video_camera_look_stop, (), {
	const v = Module.yapVideo;
	if (v) v.stopLook();
});

EM_JS(int, yap_video_camera_look_state, (), {
	const v = Module.yapVideo;
	return v ? v.lookState() : 0;
});

/* The bitrate a stream encodes at now, and the most it was asked for (kbit/s,
   0 while it isn't live); and a new one for it to encode at. */
EM_JS(int, yap_video_encoding_kbit, (int stream), {
	const v = Module.yapVideo;
	return v ? v.encodingKbit(stream) : 0;
});

EM_JS(int, yap_video_max_kbit, (int stream), {
	const v = Module.yapVideo;
	return v ? v.maxKbit(stream) : 0;
});

EM_JS(void, yap_video_set_bitrate, (int stream, int kbit), {
	const v = Module.yapVideo;
	if (v) v.setBitrate(stream, kbit);
});

EM_JS(void, yap_video_stop, (int stream), {
	const v = Module.yapVideo;
	if (v) v.stop(stream);
});

EM_JS(int, yap_video_state, (int stream), {
	const v = Module.yapVideo;
	return v ? v.state(stream) : 0;
});

/*
Puts the newest decoded frame of `sharer`'s `stream` into `texture` (a name
from glGenTextures) and says how big it is; with a sharer of 0, our own
camera's newest frame (the self view). Returns 0 if no frame has come since
the last call. A browser that can't take a VideoFrame as a texture's source
gets it by way of a 2D canvas.
*/
EM_JS(int, yap_video_upload, (unsigned int sharer, int stream, unsigned int texture, int *width, int *height), {
	const v = Module.yapVideo;
	const frame = !v ? null : sharer ? v.takeFrame(sharer, stream) : v.takePreview();
	if (!frame) return 0;
	const gl = GLctx;
	const w = frame.displayWidth, h = frame.displayHeight;
	try {
		gl.bindTexture(gl.TEXTURE_2D, GL.textures[texture]);
		try {
			gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, frame);
		} catch (e) {
			const c = Module.yapVideoCanvas || (Module.yapVideoCanvas = document.createElement("canvas"));
			if (c.width !== w || c.height !== h) { c.width = w; c.height = h; }
			c.getContext("2d").drawImage(frame, 0, 0);
			gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, c);
		}
		gl.bindTexture(gl.TEXTURE_2D, null);
	} catch (e) {
		console.warn("yap: can't draw the video:", e);
		return 0;
	} finally {
		frame.close();
	}
	HEAP32[width >> 2] = w;
	HEAP32[height >> 2] = h;
	return 1;
});

EM_JS(void, yap_video_set_fullscreen, (int on), {
	const v = Module.yapVideo;
	if (v) v.setFullscreen(on !== 0);
});

EM_JS(int, yap_video_is_fullscreen, (), {
	const v = Module.yapVideo;
	return v && v.isFullscreen() ? 1 : 0;
});

/* ---- the page ---- */

EM_JS(int, yap_query_param, (const char *name, char *buf, int buf_size), {
	const value = new URLSearchParams(location.search).get(UTF8ToString(name));
	if (!value || lengthBytesUTF8(value) + 1 > buf_size) return 0;
	stringToUTF8(value, buf, buf_size);
	return lengthBytesUTF8(value);
});

/* Puts copied text on the clipboard (src/client/ui_paste_web.odin); pasting
   is web/paste.js. The browser writes it asynchronously, and only allows
   it shortly after a key press or click, which a copy always follows. */
EM_JS(int, yap_copy_text, (const char *text), {
	if (!navigator.clipboard || !navigator.clipboard.writeText) return 0;
	navigator.clipboard.writeText(UTF8ToString(text)).catch((e) => {
		console.error("yap: could not copy to the clipboard", e);
	});
	return 1;
});

EM_JS(int, yap_open_url, (const char *url), {
	return window.open(UTF8ToString(url), "_blank", "noopener") ? 1 : 0;
});

/* Hands bytes to the browser as a file download (src/client/downloads_web.odin). */
EM_JS(int, yap_download, (const unsigned char *data, int size, const char *name), {
	try {
		// A copy: the heap view is only good until the next allocation.
		const blob = new Blob([HEAPU8.slice(data, data + size)], {type: "application/octet-stream"});
		const url = URL.createObjectURL(blob);
		const link = document.createElement("a");
		link.href = url;
		link.download = UTF8ToString(name);
		document.body.appendChild(link);
		link.click();
		link.remove();
		setTimeout(() => URL.revokeObjectURL(url), 10000);
		return 1;
	} catch (e) {
		console.error("yap: could not start the download", e);
		return 0;
	}
});

EM_JS(int, yap_utc_offset_minutes, (), {
	return -new Date().getTimezoneOffset();
});

/* The browser's language, for how dates and times are written (see
   src/client/platform/locale_web.odin). */
EM_JS(int, yap_locale, (char *buf, int buf_size), {
	const name = navigator.language || "";
	if (lengthBytesUTF8(name) + 1 > buf_size) return 0;
	stringToUTF8(name, buf, buf_size);
	return lengthBytesUTF8(name);
});

/* A browser notification (see src/client/ui_notices.odin), if the page
   may show them. Browsers only let a page ask while it's handling a
   click or a tap, so the first time one would be shown the page asks on
   the next one - the notice that prompted it has gone by then, but the
   ones after it get through. Chrome on Android doesn't let a page make
   one itself: there a service worker shows it (web/push.js). 1 if
   shown. */
EM_JS(int, yap_notify, (const char *title, const char *body), {
	if (typeof Notification === "undefined") return 0;
	if (Notification.permission === "granted") {
		const head = UTF8ToString(title);
		const text = UTF8ToString(body);
		try {
			const n = new Notification(head, text ? { body: text } : {});
			// Clicked: back to the tab it came from.
			n.onclick = () => { window.focus(); n.close(); };
		} catch (err) {
			Module.yapPush.notify(head, text);
		}
		return 1;
	}
	if (Notification.permission === "default" && !Module.yapAskToNotify) {
		Module.yapAskToNotify = true;
		const ask = () => {
			for (const type of ["pointerup", "touchend", "keyup"]) document.removeEventListener(type, ask, true);
			Notification.requestPermission();
		};
		for (const type of ["pointerup", "touchend", "keyup"]) document.addEventListener(type, ask, true);
	}
	return 0;
});

/* Web Push (web/push.js, src/client/ui_push_web.odin): a server is named
   by its address; its key is the 65 bytes of Server_Info's push_key. */
EM_JS(int, yap_push_state, (const char *server), {
	return Module.yapPush.state(UTF8ToString(server));
});

EM_JS(void, yap_push_check, (const char *server, const unsigned char *key), {
	Module.yapPush.check(UTF8ToString(server), HEAPU8.slice(key, key + 65));
});

EM_JS(void, yap_push_enable, (const char *server, const unsigned char *key), {
	Module.yapPush.enable(UTF8ToString(server), HEAPU8.slice(key, key + 65));
});

EM_JS(void, yap_push_disable, (const char *server), {
	Module.yapPush.disable(UTF8ToString(server));
});

/* The subscription to give the server, if there's a new one: the
   endpoint's length (0 for none, -1 if it doesn't fit), with the keys
   written to p256dh (65 bytes) and auth (16). */
EM_JS(int, yap_push_take, (const char *server, char *endpoint, int size, unsigned char *p256dh, unsigned char *auth), {
	const sub = Module.yapPush.take(UTF8ToString(server));
	if (!sub) return 0;
	const n = lengthBytesUTF8(sub.endpoint);
	if (n + 1 > size || sub.p256dh.length !== 65 || sub.auth.length !== 16) return -1;
	stringToUTF8(sub.endpoint, endpoint, size);
	HEAPU8.set(sub.p256dh, p256dh);
	HEAPU8.set(sub.auth, auth);
	return n;
});

EM_JS(int, yap_push_take_unsubscribe, (const char *server), {
	return Module.yapPush.takeUnsubscribe(UTF8ToString(server)) ? 1 : 0;
});

EM_JS(void, yap_push_seen, (const char *server, unsigned int conv), {
	Module.yapPush.seen(UTF8ToString(server), conv);
});

/* What a tapped notification asked to show: the server's address's
   length (0 for nothing), with the conversation and message. */
EM_JS(int, yap_push_take_open, (char *server, int size, unsigned int *conv, double *msg), {
	const o = Module.yapPush.takeOpen();
	if (!o) return 0;
	const n = lengthBytesUTF8(o.server);
	if (n + 1 > size) return 0;
	stringToUTF8(o.server, server, size);
	HEAPU32[conv >> 2] = o.conv;
	HEAPF64[msg >> 3] = o.msg;
	return n;
});

/* The number on the installed app's icon (web/push.js): unread DMs and
   mentions; 0 takes it away. */
EM_JS(void, yap_set_badge, (int n), {
	Module.yapPush.badge(n);
});

/* Whether the page is out of sight: a hidden tab, a phone's browser in
   the background. Someone who can't see it is as good as idle, so the
   server pushes to them (src/client/ui_activity.odin). */
EM_JS(int, yap_page_hidden, (void), {
	return document.hidden ? 1 : 0;
});

/* Puts a phone's keyboard away: the hidden field that brought it up
   (web/touch.js) lets go of the focus. */
EM_JS(void, yap_keyboard_hide, (), {
	const field = document.getElementById("yap-keyboard");
	if (field && document.activeElement === field) field.blur();
});

/* Labels a phone keyboard's Enter key for the text box that has the focus:
   a new line in a text area (src/client/ui_text_area.odin), else send. */
EM_JS(void, yap_keyboard_multiline, (int on), {
	const field = document.getElementById("yap-keyboard");
	if (field) field.enterKeyHint = on ? "enter" : "send";
});

/* The page's text fields that stand in for the client's text areas
   (web/field.js, src/client/ui_field_web.odin). */
EM_JS(void, yap_field_font, (const unsigned char *data, int n), {
	Module.yapField.font(HEAPU8.slice(data, data + n));
});

EM_JS(void, yap_field_text, (unsigned int id, const char *text, int n, int caret, int anchor), {
	Module.yapField.text(id >>> 0, n > 0 ? UTF8ToString(text, n) : "", caret, anchor);
});

EM_JS(void, yap_field_select, (unsigned int id, int caret, int anchor), {
	Module.yapField.select(id >>> 0, caret, anchor);
});

EM_JS(void, yap_fields_begin, (void), {
	Module.yapField.begin();
});

EM_JS(void, yap_field_place, (unsigned int id, double x, double y, double w, double h, double cx, double cy, double cw, double ch, double pad_x, double pad_top, double pad_bottom, double em, double line, unsigned int color, unsigned int selection, int flags), {
	Module.yapField.place(id >>> 0, x, y, w, h, cx, cy, cw, ch, pad_x, pad_top, pad_bottom, em, line, color >>> 0, selection >>> 0, flags);
});

EM_JS(void, yap_fields_end, (void), {
	Module.yapField.end();
});

/* ---- the canvas' pixels ---- */

/* Sizes the canvas' backing store to exactly the device pixels it covers,
   and says what that is (src/client/wglfw/wglfw_web.odin, GetFramebufferSize).

   Emscripten's GLFW makes it floor(CSS size * devicePixelRatio), which is
   right for a whole ratio, but a fractional one (125%, 150%, a zoomed
   page) rarely lands on whole pixels: 1001 CSS px at 1.5 cover 1501.5.
   The browser then stretches the canvas to fit, and the UI comes out
   soft and uneven. It also only notices the ratio change once, so after
   a zoom or a move to another screen it can stay at the wrong one.

   The browser knows the exact answer - the canvas' device-pixel content
   box, as it snaps it to the screen - and reports it to a ResizeObserver,
   whenever it changes. Where that isn't supported, rounding the CSS size
   times the ratio is the best guess. This runs every frame, so whatever
   GLFW sets the canvas to is put right before it's drawn in. */
EM_JS(void, yap_canvas_fit, (int *width, int *height), {
	const canvas = Module.canvas;
	if (!Module.yapCanvasFit) {
		const fit = { box: null };
		Module.yapCanvasFit = fit;
		try {
			new ResizeObserver((entries) => {
				const size = entries[entries.length - 1].devicePixelContentBoxSize;
				if (size && size[0]) fit.box = [size[0].inlineSize, size[0].blockSize];
			}).observe(canvas, { box: "device-pixel-content-box" });
		} catch (e) {
			/* No device-pixel-content-box here: the guess below it is. */
		}
	}
	let w, h;
	const box = Module.yapCanvasFit.box;
	if (box) {
		[w, h] = box;
	} else {
		const rect = canvas.getBoundingClientRect();
		const ratio = window.devicePixelRatio || 1;
		w = Math.round(rect.width * ratio);
		h = Math.round(rect.height * ratio);
	}
	if (w > 0 && h > 0) {
		if (canvas.width !== w) canvas.width = w;
		if (canvas.height !== h) canvas.height = h;
	}
	HEAP32[width >> 2] = canvas.width;
	HEAP32[height >> 2] = canvas.height;
});

/* Device pixels per CSS pixel (src/client/wglfw/wglfw_web.odin). */
EM_JS(double, yap_device_pixel_ratio, (), {
	return window.devicePixelRatio || 1;
});

int main(void) {
	if (!web_start()) {
		printf("yap: the client could not start\n");
		return 1;
	}
	emscripten_set_main_loop(web_frame, 0, 1);
	return 0;
}

/* Choosing our picture (web/avatar.js, src/client/ui_avatar_pick_web.odin). */
/* Whether the system is dark, as the page sees it (src/client/theme.odin). */
EM_JS(int, yap_prefers_dark, (void), {
	return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches ? 1 : 0;
});

/* What the browser and system are, for the account's list of devices
   (src/client/platform/agent_web.odin): "Firefox 128 on Windows". */
EM_JS(int, yap_agent, (char *buf, int buf_size), {
	const ua = navigator.userAgent || "";
	const hint = navigator.userAgentData;
	let browser = "";
	/* Order matters: most of these also say Chrome or Safari. No backslashes:
	   this is a C string, which would eat them. */
	for (const [re, name] of [
		[/Edg(?:e|A|iOS)?[/]([0-9]+)/, "Edge"],
		[/OPR[/]([0-9]+)/, "Opera"],
		[/(?:Firefox|FxiOS)[/]([0-9]+)/, "Firefox"],
		[/(?:Chrome|CriOS)[/]([0-9]+)/, "Chrome"],
		[/Version[/]([0-9]+)[^]*Safari/, "Safari"],
	]) {
		const m = ua.match(re);
		if (m) { browser = name + " " + m[1]; break; }
	}
	if (!browser) browser = "Browser";
	let os = "";
	const platform = hint && hint.platform ? hint.platform : "";
	if (/Android/.test(ua)) os = "Android";
	else if (/iPhone|iPad|iPod/.test(ua)) os = "iOS";
	else if (/CrOS/.test(ua)) os = "ChromeOS";
	else if (/Windows/.test(ua) || platform === "Windows") os = "Windows";
	else if (/Mac/.test(ua) || platform === "macOS") os = "macOS";
	else if (/Linux|X11/.test(ua)) os = "Linux";
	const text = os ? browser + " on " + os : browser;
	if (lengthBytesUTF8(text) + 1 > buf_size) return 0;
	stringToUTF8(text, buf, buf_size);
	return lengthBytesUTF8(text);
});

EM_JS(void, yap_avatar_pick, (int side, int size), {
	Module.yapAvatar.pick(side, size);
});

/* Sound files of the user's own (web/sounds.js, src/client/ui_sounds_web.odin). */
EM_JS(void, yap_sound_pick, (int kind), {
	Module.yapSounds.pick(kind);
});

EM_JS(void, yap_sound_load, (const char *name), {
	Module.yapSounds.load(UTF8ToString(name));
});

EM_JS(void, yap_sound_remove, (const char *name), {
	Module.yapSounds.remove(UTF8ToString(name));
});

/* Files in DMs (web/files.js, src/client/files_io_web.odin). */
EM_JS(void, yap_file_pick, (const char *accept, int multiple), {
	Module.yapFiles.pick(UTF8ToString(accept), multiple);
});

EM_JS(int, yap_file_read, (int handle, double offset, unsigned char *buf, int len), {
	return Module.yapFiles.read(handle, offset, buf, len);
});

EM_JS(void, yap_file_close, (int handle), {
	Module.yapFiles.close(handle);
});

EM_JS(int, yap_sink_open, (const char *name, double size), {
	return Module.yapFiles.sinkOpen(UTF8ToString(name), size);
});

EM_JS(int, yap_sink_write, (int handle, double offset, const unsigned char *data, int len), {
	return Module.yapFiles.sinkWrite(handle, offset, data, len);
});

EM_JS(int, yap_sink_finish, (int handle), {
	return Module.yapFiles.sinkFinish(handle);
});

EM_JS(void, yap_sink_abort, (int handle), {
	Module.yapFiles.sinkAbort(handle);
});

/* The image cache (web/images.js, src/client/conn/image_cache_web.odin). */
EM_JS(int, yap_image_cache_open, (double max_bytes), {
	return Module.yapImages.open(max_bytes);
});

EM_JS(double, yap_image_cache_bytes, (void), {
	return Module.yapImages.bytes();
});

EM_JS(int, yap_image_cache_count, (void), {
	return Module.yapImages.count();
});

EM_JS(void, yap_image_cache_set_max, (double max_bytes), {
	Module.yapImages.setMax(max_bytes);
});

EM_JS(void, yap_image_cache_clear, (void), {
	Module.yapImages.clear();
});

EM_JS(int, yap_image_cache_request, (const char *key), {
	return Module.yapImages.request(UTF8ToString(key));
});

EM_JS(int, yap_image_cache_poll, (int req), {
	return Module.yapImages.poll(req);
});

EM_JS(void, yap_image_cache_take, (int req, unsigned char *buf, int len), {
	Module.yapImages.take(req, buf, len);
});

EM_JS(void, yap_image_cache_cancel, (int req), {
	Module.yapImages.cancel(req);
});

EM_JS(void, yap_image_cache_store, (const char *key, const unsigned char *data, int len), {
	Module.yapImages.store(UTF8ToString(key), data, len);
});

/* Pictures decoded by the browser (web/decode.js, src/client/ui_images_worker_web.odin). */
EM_JS(int, yap_image_decode_start, (const unsigned char *data, int len, double max_pixels, int max_side), {
	return Module.yapDecode.start(data, len, max_pixels, max_side);
});

EM_JS(int, yap_image_decode_poll, (int req), {
	return Module.yapDecode.poll(req);
});

EM_JS(int, yap_image_decode_width, (int req), {
	return Module.yapDecode.width(req);
});

EM_JS(int, yap_image_decode_height, (int req), {
	return Module.yapDecode.height(req);
});

EM_JS(int, yap_image_decode_full_width, (int req), {
	return Module.yapDecode.fullWidth(req);
});

EM_JS(int, yap_image_decode_full_height, (int req), {
	return Module.yapDecode.fullHeight(req);
});

EM_JS(void, yap_image_decode_take, (int req, unsigned char *buf), {
	Module.yapDecode.take(req, buf);
});

EM_JS(int, yap_image_decode_kind, (int req), {
	return Module.yapDecode.kind(req);
});

EM_JS(int, yap_image_decode_shown, (int req), {
	return Module.yapDecode.shown(req);
});

EM_JS(int, yap_image_decode_next, (int req), {
	return Module.yapDecode.next(req);
});

EM_JS(void, yap_image_decode_close, (int req), {
	Module.yapDecode.close(req);
});
