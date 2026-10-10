/*
Pasting a picture into the chat, for the web client (emcc --pre-js, see
web/build.sh). A page can only read the clipboard inside the paste event
the user caused, so this listens for that event and does the whole job
here: it decodes the picture, scales it down to fit MAX_SIDE and
compresses it to a WebP within MAX_BYTES - the same budget image.odin
keeps on a desktop, and the same order of giving things up: quality
first, then size - then hands it to the client as a file to attach
(web/files.js keeps it; web_file_pasted, src/client/ui_paste_web.odin).
A browser that can't write WebP (Safari, which writes a PNG instead) is
given the JPEG this made before WebP, at the qualities it had then.

Transparent parts are put on white, as image.odin does.

An animated GIF or WebP no bigger than the server takes is sent as it
is instead, as on a desktop (src/client/ui_paste.odin).
The text of every paste goes to the client as well (web_paste_text),
which is where its text boxes paste from: emscripten's GLFW has no
clipboard.
*/
(() => {
	// Keep these in step with src/client/image.odin.
	const MAX_SIDE = 3840;
	const MAX_BYTES = 256 * 1024;
	const MAX_SCALE_ROUNDS = 4;
	// Quality for the first try, the second (same size) and the ones that
	// shrink, for each format.
	const WEBP = { type: "image/webp", ext: "webp", first: 0.8, second: 0.6, scaled: 0.7 };
	const JPEG = { type: "image/jpeg", ext: "jpg", first: 0.85, second: 0.6, scaled: 0.75 };

	const toBlob = (canvas, type, quality) =>
		new Promise((resolve) => canvas.toBlob(resolve, type, quality));

	const prepare = async (file) => {
		const bitmap = await createImageBitmap(file);
		try {
			return (await compress(bitmap, WEBP)) || (await compress(bitmap, JPEG));
		} finally {
			bitmap.close();
		}
	};

	// compress is the picture in `format` within the budget, as { blob,
	// ext }, or null if the browser won't write it (or it never fits).
	const compress = async (bitmap, format) => {
		let w = bitmap.width;
		let h = bitmap.height;
		if (w > MAX_SIDE || h > MAX_SIDE) {
			const k = MAX_SIDE / Math.max(w, h);
			w = Math.max(Math.floor(w * k), 1);
			h = Math.max(Math.floor(h * k), 1);
		}
		const canvas = document.createElement("canvas");
		let quality = format.first;
		for (let round = 0; round <= MAX_SCALE_ROUNDS + 1; round++) {
			canvas.width = w;
			canvas.height = h;
			const g = canvas.getContext("2d");
			g.fillStyle = "#fff";
			g.fillRect(0, 0, w, h);
			g.imageSmoothingQuality = "high";
			g.drawImage(bitmap, 0, 0, w, h);
			const blob = await toBlob(canvas, format.type, quality);
			// Not written in this format at all, but as a PNG.
			if (!blob || blob.type !== format.type) return null;
			if (blob.size <= MAX_BYTES) return { blob, ext: format.ext };
			if (round === 0) {
				quality = format.second; // same size, cheaper bits first
				continue;
			}
			if (w <= 64 || h <= 64 || round > MAX_SCALE_ROUNDS) break;
			quality = format.scaled;
			// A picture's size roughly follows its pixel count.
			const k = Math.min(Math.max(0.95 * Math.sqrt(MAX_BYTES / blob.size), 0.25), 0.9);
			w = Math.max(Math.floor(w * k), 1);
			h = Math.max(Math.floor(h * k), 1);
		}
		return null;
	};

	// The client names it (pasted_image_name), with this name's extension;
	// "pasted-animation" says it went as it was (animation).
	const send = ({ blob, ext }, name = "pasted-image") => {
		const file = new File([blob], `${name}.${ext}`, { type: blob.type });
		Module.yapFiles.tell(file, Module._web_file_pasted);
	};

	// How many frames a GIF has, counted from its blocks (as gif_info in
	// src/client/ui_images_anim_native.odin), up to 2: all that matters.
	const gifFrames = (b) => {
		if (b.length < 13 || b[0] !== 0x47 || b[1] !== 0x49 || b[2] !== 0x46) return 0;
		let pos = 13;
		if (b[10] & 0x80) pos += 3 << ((b[10] & 7) + 1);
		const skip = () => {
			while (pos < b.length) {
				const n = b[pos++];
				if (n === 0) return true;
				pos += n;
			}
			return false;
		};
		let frames = 0;
		while (pos < b.length && frames < 2) {
			if (b[pos] === 0x2c) {
				if (pos + 10 > b.length) break;
				const flags = b[pos + 9];
				pos += 10;
				if (flags & 0x80) pos += 3 << ((flags & 7) + 1);
				pos++; // the LZW code size
				if (!skip()) break;
				frames++;
			} else if (b[pos] === 0x21) {
				pos += 2;
				if (!skip()) break;
			} else {
				break;
			}
		}
		return frames;
	};

	/*
	animation is the extension of a GIF or WebP that's animated and no
	bigger than the server takes, which is sent as it is (compressing it
	would leave its first frame); null for anything else.
	*/
	const animation = async (file) => {
		if (file.type !== "image/gif" && file.type !== "image/webp") return null;
		if (file.size > Module._web_max_attachment()) return null;
		const b = new Uint8Array(await file.arrayBuffer());
		const tag = (at) => String.fromCharCode(b[at], b[at + 1], b[at + 2], b[at + 3]);
		if (b.length >= 21 && tag(0) === "RIFF" && tag(8) === "WEBP" && tag(12) === "VP8X" && b[20] & 2) {
			return "webp";
		}
		return gifFrames(b) > 1 ? "gif" : null;
	};

	// The text, for the client to paste when it gets to the Ctrl+V (see
	// src/client/ui_paste_web.odin); empty for a paste without any. The
	// on-screen keyboard's field (web/touch.js) takes its pastes itself.
	const sendText = (text) => {
		const bytes = new TextEncoder().encode(text);
		const ptr = _malloc(bytes.length + 1);
		HEAPU8.set(bytes, ptr);
		Module._web_paste_text(ptr, bytes.length);
		_free(ptr);
	};

	document.addEventListener("paste", async (event) => {
		if (typeof Module._web_file_pasted !== "function") return;
		const target = event.target;
		if (target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement) return;
		sendText(event.clipboardData ? event.clipboardData.getData("text/plain") : "");
		const items = event.clipboardData ? Array.from(event.clipboardData.items) : [];
		const images = items.filter((i) => i.kind === "file" && i.type.startsWith("image/"));
		// A GIF or WebP first: either may be an animation.
		const item = images.find((i) => i.type === "image/gif" || i.type === "image/webp") || images[0];
		if (!item) return;
		const file = item.getAsFile();
		if (!file) return;
		event.preventDefault();
		try {
			const ext = await animation(file);
			if (ext) {
				send({ blob: file, ext }, "pasted-animation");
				return;
			}
			const result = await prepare(file);
			if (result) send(result);
			else Module._web_paste_failed();
		} catch (e) {
			console.error("yap: could not prepare the pasted image", e);
			Module._web_paste_failed();
		}
	});
})();
