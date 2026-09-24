/*
Pasting a picture into the chat, for the web client (emcc --pre-js, see
web/build.sh). A page can only read the clipboard inside the paste event
the user caused, so this listens for that event and does the whole job
here: it decodes the picture, scales it down to fit MAX_SIDE and
compresses it to a JPEG within MAX_BYTES - the same budget image.odin
keeps on a desktop, and the same order of giving things up: quality
first, then size - then hands the JPEG to the client (web_paste_image,
client/ui_paste_web.odin).

Transparent parts are put on white, since JPEG has no transparency.
Text on the clipboard is left alone for the client to paste.
*/
(() => {
	// Keep these in step with client/image.odin.
	const MAX_SIDE = 3840;
	const MAX_BYTES = 256 * 1024;
	const QUALITY_FIRST = 0.85;
	const QUALITY_SECOND = 0.6;
	const QUALITY_SCALED = 0.75;
	const MAX_SCALE_ROUNDS = 4;

	const toBlob = (canvas, quality) =>
		new Promise((resolve) => canvas.toBlob(resolve, "image/jpeg", quality));

	const prepare = async (file) => {
		const bitmap = await createImageBitmap(file);
		let w = bitmap.width;
		let h = bitmap.height;
		if (w > MAX_SIDE || h > MAX_SIDE) {
			const k = MAX_SIDE / Math.max(w, h);
			w = Math.max(Math.floor(w * k), 1);
			h = Math.max(Math.floor(h * k), 1);
		}
		const canvas = document.createElement("canvas");
		let quality = QUALITY_FIRST;
		for (let round = 0; round <= MAX_SCALE_ROUNDS + 1; round++) {
			canvas.width = w;
			canvas.height = h;
			const g = canvas.getContext("2d");
			g.fillStyle = "#fff";
			g.fillRect(0, 0, w, h);
			g.imageSmoothingQuality = "high";
			g.drawImage(bitmap, 0, 0, w, h);
			const blob = await toBlob(canvas, quality);
			if (!blob) break;
			if (blob.size <= MAX_BYTES) {
				bitmap.close();
				return { bytes: new Uint8Array(await blob.arrayBuffer()), w, h };
			}
			if (round === 0) {
				quality = QUALITY_SECOND; // same size, cheaper bits first
				continue;
			}
			if (w <= 64 || h <= 64 || round > MAX_SCALE_ROUNDS) break;
			quality = QUALITY_SCALED;
			// A JPEG's size roughly follows its pixel count.
			const k = Math.min(Math.max(0.95 * Math.sqrt(MAX_BYTES / blob.size), 0.25), 0.9);
			w = Math.max(Math.floor(w * k), 1);
			h = Math.max(Math.floor(h * k), 1);
		}
		bitmap.close();
		return null;
	};

	const send = ({ bytes, w, h }) => {
		const ptr = _malloc(bytes.length);
		HEAPU8.set(bytes, ptr);
		Module._web_paste_image(ptr, bytes.length, w, h);
		_free(ptr);
	};

	document.addEventListener("paste", async (event) => {
		if (typeof Module._web_paste_image !== "function") return;
		const items = event.clipboardData ? Array.from(event.clipboardData.items) : [];
		const item = items.find((i) => i.kind === "file" && i.type.startsWith("image/"));
		if (!item) return;
		const file = item.getAsFile();
		if (!file) return;
		event.preventDefault();
		try {
			const result = await prepare(file);
			if (result) send(result);
			else Module._web_paste_failed();
		} catch (e) {
			console.error("yap: could not prepare the pasted image", e);
			Module._web_paste_failed();
		}
	});
})();
