/*
Choosing our picture, for the web client (emcc --pre-js, see
web/build.sh and src/client/ui_avatar_pick_web.odin). A file input the
page clicks for the client; the picture is made here, the way
avatar_prepare (src/client/image.odin) makes it on a desktop: the
largest square from its centre, scaled down to MAX_SIDE, and compressed
to a JPEG within MAX_BYTES by lowering the quality till it fits. A
server's picture is made the same way, smaller: the client says how big
(proto.MAX_SERVER_ICON_SIDE and MAX_SERVER_ICON_SIZE).
Transparent parts are put on white, since JPEG has no transparency.

The client is told when a file was chosen (web_avatar_reading, for its
"reading the picture..."), then of the result: the JPEG
(web_avatar_picked) or that it couldn't be made (web_avatar_failed).
Closing the dialog without a choice tells it nothing.
*/
(() => {
	// The defaults: keep these in step with proto.MAX_AVATAR_SIDE and
	// MAX_AVATAR_SIZE.
	const MAX_SIDE = 256;
	const MAX_BYTES = 64 * 1024;
	// 88, 76, 64, 52, 40: as avatar_prepare tries them.
	const QUALITIES = [0.88, 0.76, 0.64, 0.52, 0.4];

	const toBlob = (canvas, quality) =>
		new Promise((resolve) => canvas.toBlob(resolve, "image/jpeg", quality));

	const prepare = async (file, maxSide, maxBytes) => {
		const bitmap = await createImageBitmap(file);
		try {
			const side = Math.min(bitmap.width, bitmap.height);
			if (side <= 0) return null;
			const out = Math.min(side, maxSide);
			const canvas = document.createElement("canvas");
			canvas.width = out;
			canvas.height = out;
			const g = canvas.getContext("2d");
			g.fillStyle = "#fff";
			g.fillRect(0, 0, out, out);
			g.imageSmoothingQuality = "high";
			const x0 = Math.floor((bitmap.width - side) / 2);
			const y0 = Math.floor((bitmap.height - side) / 2);
			g.drawImage(bitmap, x0, y0, side, side, 0, 0, out, out);
			for (const quality of QUALITIES) {
				const blob = await toBlob(canvas, quality);
				if (!blob) return null;
				if (blob.size <= maxBytes) {
					return { bytes: new Uint8Array(await blob.arrayBuffer()), side: out };
				}
			}
			return null;
		} finally {
			bitmap.close();
		}
	};

	const send = ({ bytes, side }) => {
		const ptr = _malloc(bytes.length);
		HEAPU8.set(bytes, ptr);
		Module._web_avatar_picked(ptr, bytes.length, side);
		_free(ptr);
	};

	Module.yapAvatar = {
		pick(maxSide = MAX_SIDE, maxBytes = MAX_BYTES) {
			const input = document.createElement("input");
			input.type = "file";
			input.accept = "image/*";
			input.addEventListener("change", async () => {
				const file = input.files && input.files[0];
				if (!file || typeof Module._web_avatar_picked !== "function") return;
				Module._web_avatar_reading();
				try {
					const result = await prepare(file, maxSide, maxBytes);
					if (result) send(result);
					else Module._web_avatar_failed();
				} catch (e) {
					console.error("yap: could not prepare the picture", e);
					Module._web_avatar_failed();
				}
			});
			input.click();
		},
	};
})();
