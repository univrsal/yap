/*
Decoding pictures, for the web client (emcc --pre-js, see web/build.sh
and src/client/ui_images_worker_web.odin). The browser does it, off the
page's one thread (createImageBitmap), and reads every format it knows:
WebP, which stb_image doesn't, as well as PNG, JPEG, GIF and BMP. The
pixels come out of a canvas as straight (not premultiplied) RGBA.

The client hands over the bytes (start), and once a picture is done the
page asks it for a frame (web_image_decoded), in which the client looks
(poll) and copies the pixels out (take). The colour profile a picture
carries is ignored, as stb_image ignores it on a desktop.
*/
(() => {
	const requests = new Map(); // handle -> { state, width, height, data }
	let next = 1;

	const canvasOf = (width, height) => {
		if (typeof OffscreenCanvas !== "undefined") return new OffscreenCanvas(width, height);
		const canvas = document.createElement("canvas");
		canvas.width = width;
		canvas.height = height;
		return canvas;
	};

	const decode = async (r, bytes, maxPixels) => {
		const bitmap = await createImageBitmap(new Blob([bytes]), {
			premultiplyAlpha: "none",
			colorSpaceConversion: "none",
		});
		try {
			const { width, height } = bitmap;
			if (width <= 0 || height <= 0 || width * height > maxPixels) {
				throw new Error(`${width}x${height} is over the limit`);
			}
			const g = canvasOf(width, height).getContext("2d", { willReadFrequently: true });
			g.drawImage(bitmap, 0, 0);
			r.data = g.getImageData(0, 0, width, height).data;
			r.width = width;
			r.height = height;
		} finally {
			bitmap.close();
		}
	};

	Module.yapDecode = {
		// The bytes are copied out here, so the client can free them.
		start(ptr, len, maxPixels) {
			const handle = next++;
			const r = { state: "pending" };
			requests.set(handle, r);
			decode(r, HEAPU8.slice(ptr, ptr + len), maxPixels)
				.then(() => {
					r.state = "done";
				})
				.catch((e) => {
					console.warn("yap: could not decode a picture:", e);
					r.state = "failed";
				})
				.finally(() => {
					if (requests.has(handle) && typeof Module._web_image_decoded === "function") {
						Module._web_image_decoded();
					}
				});
			return handle;
		},

		// -1 while it's being decoded, -2 if it can't be, else 1: then
		// width and height say how big it is, and take copies it out.
		poll(handle) {
			const r = requests.get(handle);
			if (!r || r.state === "failed") {
				requests.delete(handle);
				return -2;
			}
			return r.state === "pending" ? -1 : 1;
		},

		width(handle) {
			const r = requests.get(handle);
			return r && r.data ? r.width : 0;
		},

		height(handle) {
			const r = requests.get(handle);
			return r && r.data ? r.height : 0;
		},

		take(handle, ptr) {
			const r = requests.get(handle);
			requests.delete(handle);
			if (r && r.data) HEAPU8.set(r.data, ptr);
		},
	};
})();
