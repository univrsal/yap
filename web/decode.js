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

An animated GIF or WebP plays where the browser has WebCodecs'
ImageDecoder (elsewhere it's its first frame, as a still picture): its
first frame is taken as any picture's, and the request is kept, the
decoder with it, for the client to ask for the next frame (next) while
the picture plays, and to let go of it (close). As on a desktop
(src/client/ui_images_anim_native.odin), frames under 33 ms are merged
with the next, and one that says 10 ms or less is shown for 100.
*/
(() => {
	const requests = new Map(); // handle -> { state, width, height, data, anim, shown }
	let next = 1;

	// The least a frame handed over is shown for, in milliseconds.
	const MIN_SHOWN = 33;

	const canvasOf = (width, height) => {
		if (typeof OffscreenCanvas !== "undefined") return new OffscreenCanvas(width, height);
		const canvas = document.createElement("canvas");
		canvas.width = width;
		canvas.height = height;
		return canvas;
	};

	// The pixels of a bitmap or a VideoFrame, as straight RGBA.
	const pixelsOf = (r, image, width, height, maxPixels) => {
		if (width <= 0 || height <= 0 || width * height > maxPixels) {
			throw new Error(`${width}x${height} is over the limit`);
		}
		const g = canvasOf(width, height).getContext("2d", { willReadFrequently: true });
		g.drawImage(image, 0, 0);
		r.data = g.getImageData(0, 0, width, height).data;
		r.width = width;
		r.height = height;
	};

	// The kind of animation the bytes may be, by how they start.
	const animType = (b) => {
		if (b.length >= 6 && b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46) return "image/gif";
		const tag = (at) => String.fromCharCode(b[at], b[at + 1], b[at + 2], b[at + 3]);
		if (b.length >= 21 && tag(0) === "RIFF" && tag(8) === "WEBP" && tag(12) === "VP8X" && b[20] & 2) {
			return "image/webp";
		}
		return null;
	};

	// How long a frame that says `us` microseconds is shown, in ms.
	const frameMs = (us) => {
		const ms = (us || 0) / 1000;
		return ms <= 10 ? 100 : Math.max(ms, 20);
	};

	/*
	An animation's next frame into r.data, and how long it's shown into
	r.shown; false when there are no more (it has played as often as it
	says).
	*/
	const nextFrame = async (r, maxPixels) => {
		const a = r.anim;
		let ms = 0;
		let frame = null;
		let resets = 0;
		try {
			while (ms < MIN_SHOWN) {
				if (a.index >= a.count) {
					if (frame) break; // what's taken is shown before going round again
					a.rounds++;
					resets++;
					if ((a.plays !== 0 && a.rounds >= a.plays) || resets > 1) return false;
					a.index = 0;
				}
				const { image } = await a.dec.decode({ frameIndex: a.index++ });
				if (frame) frame.close();
				frame = image;
				ms += frameMs(image.duration);
			}
			pixelsOf(r, frame, frame.displayWidth, frame.displayHeight, maxPixels);
			r.shown = Math.round(ms);
			return true;
		} finally {
			if (frame) frame.close();
		}
	};

	// Starts playing the bytes if they're an animation the browser can
	// play; false (and nothing kept) if not.
	const startAnim = async (r, bytes, maxPixels) => {
		const type = animType(bytes);
		if (!type || typeof ImageDecoder === "undefined") return false;
		if (!(await ImageDecoder.isTypeSupported(type))) return false;
		const dec = new ImageDecoder({
			data: bytes,
			type,
			premultiplyAlpha: "none",
			colorSpaceConversion: "none",
		});
		try {
			await dec.tracks.ready;
			await dec.completed;
			const track = dec.tracks.selectedTrack;
			if (!track || !track.animated || track.frameCount <= 1) {
				dec.close();
				return false;
			}
			r.anim = {
				dec,
				count: track.frameCount,
				// How often it plays: 0 is for ever.
				plays: track.repetitionCount === Infinity ? 0 : track.repetitionCount + 1,
				index: 0,
				rounds: 0,
				gif: type === "image/gif",
				maxPixels,
			};
			if (!(await nextFrame(r, maxPixels))) throw new Error("no frames");
			return true;
		} catch (e) {
			dec.close();
			r.anim = null;
			console.warn("yap: could not play an animation, showing it still:", e);
			return false;
		}
	};

	const decode = async (r, bytes, maxPixels) => {
		if (await startAnim(r, bytes, maxPixels)) return;
		const bitmap = await createImageBitmap(new Blob([bytes]), {
			premultiplyAlpha: "none",
			colorSpaceConversion: "none",
		});
		try {
			pixelsOf(r, bitmap, bitmap.width, bitmap.height, maxPixels);
		} finally {
			bitmap.close();
		}
	};

	// Wakes the client, for a frame in which it looks for what's done.
	const wake = (handle) => {
		if (requests.has(handle) && typeof Module._web_image_decoded === "function") {
			Module._web_image_decoded();
		}
	};

	// Animations play only while the page has the focus (anims_running):
	// a frame when that changes, so they carry on.
	const focusChanged = () => {
		if (typeof Module._web_image_decoded === "function") Module._web_image_decoded();
	};
	window.addEventListener("focus", focusChanged);
	window.addEventListener("blur", focusChanged);
	document.addEventListener("visibilitychange", focusChanged);

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
				.finally(() => wake(handle));
			return handle;
		},

		// -1 while it's being decoded, -2 if it can't be, else 1: then
		// width and height say how big it is, and take copies it out. For
		// an animation's next frame (next), 2 says there are no more.
		poll(handle) {
			const r = requests.get(handle);
			if (!r || r.state === "failed") {
				requests.delete(handle);
				if (r && r.anim) r.anim.dec.close();
				return -2;
			}
			if (r.state === "ended") return 2;
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

		// 0 for a still picture, 1 for an animated WebP, 2 for a GIF.
		kind(handle) {
			const r = requests.get(handle);
			if (!r || !r.anim) return 0;
			return r.anim.gif ? 2 : 1;
		},

		// How long the frame taken is shown, in milliseconds.
		shown(handle) {
			const r = requests.get(handle);
			return r && r.anim ? r.shown : 0;
		},

		// Done with the handle, unless it's an animation's: that's kept
		// until close.
		take(handle, ptr) {
			const r = requests.get(handle);
			if (r && r.data) HEAPU8.set(r.data, ptr);
			if (r && r.anim) {
				r.data = null;
				r.state = "idle";
			} else {
				requests.delete(handle);
			}
		},

		// Starts on an animation's next frame, polled for as the first; 0
		// if the handle isn't an animation waiting for that. The client
		// isn't woken for it: it looks when the frame is due (anim_drawn).
		next(handle) {
			const r = requests.get(handle);
			if (!r || !r.anim || r.state !== "idle") return 0;
			r.state = "pending";
			nextFrame(r, r.anim.maxPixels)
				.then((more) => {
					r.state = more ? "done" : "ended";
				})
				.catch((e) => {
					console.warn("yap: could not decode an animation's frame:", e);
					r.state = "failed";
				});
			return 1;
		},

		close(handle) {
			const r = requests.get(handle);
			requests.delete(handle);
			if (r && r.anim) r.anim.dec.close();
		},
	};
})();
