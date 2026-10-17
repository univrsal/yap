/*
Screen sharing, the browser's half (emcc --pre-js, see web/build.sh): it
captures the screen and encodes it, and decodes and shows what somebody
else shares. The client carries the encoded frames (src/client/video.odin)
and reaches this through Module.yapVideo (web/shell.c).

Sharing: getDisplayMedia's track is scaled to fit 1920x1080, sampled at
FPS and encoded as H.264 (Annex B, so every keyframe carries what the
decoder needs to start). Encoded frames wait in a queue until the client
pulls them. The frames come from a MediaStreamTrackProcessor where there
is one, otherwise from a <video> playing the stream, sampled from a
worker's timer - either keeps going when this tab is hidden, which it
usually is while another tab is being shared.

Where the browser shares audio with the picture (Chromium: a tab's, or on
Windows the whole system's along with a screen), an AudioWorklet takes it at
48 kHz stereo and it waits in a queue until the client pulls it, to send
mixed into our voice like a shared application's (src/client/conn/video_web.odin).
restrictOwnAudio leaves out what this page plays, so nobody hears
themselves back.

Watching: frames go to a VideoDecoder - H.264, and HEVC and AV1 where
the browser takes them (decodable, which the client tells the others so
their shares keep to it) - and the newest decoded one waits
until the client draws it, which it does in its own canvas as a texture
(takeFrame, yap_video_upload in web/shell.c) - older ones are let go
unseen. A decoder that fails says so through takeError, and the client
asks for a new keyframe. Fullscreen is the whole page's; the client then
shows nothing but the picture.

Neither needs the other: a browser with VideoDecoder but no VideoEncoder
or getDisplayMedia (a phone) can still watch.
*/
(() => {
	const FPS = 30;
	const BITRATE = 2000000; // what src/client/video.odin paces for, and a bit under
	const KEY_INTERVAL_MS = 5000;
	const MAX_LONG_SIDE = 1920;
	const MAX_SHORT_SIDE = 1080;
	// Frames the client hasn't pulled; more means it isn't running.
	const MAX_QUEUED = 30;
	// Frames waiting in the decoder; more means it can't keep up.
	const MAX_DECODING = 30;
	// Shared audio the client hasn't pulled, in samples (interleaved
	// stereo at 48 kHz): half a second. Older audio is dropped.
	const AUDIO_RATE = 48000;
	const MAX_AUDIO_QUEUED = AUDIO_RATE;
	// Constrained Baseline, Main, High, all at level 4 (1080p30).
	const H264_CODECS = ["avc1.42E028", "avc1.4D0028", "avc1.640028"];
	// The other codecs, by their number in src/common/proto/video.odin:
	// HEVC Main and AV1 Main (8-bit), both at level 5.1 (4K60), which is
	// as far as a native share goes. Both come without a description:
	// HEVC as Annex B, AV1 as OBUs with sizes.
	const H264 = 0;
	const OTHER_CODECS = { 1: "hev1.1.6.L153.B0", 2: "av01.0.13M.08" };

	// What the client's Share_State says (src/client/video_web.odin).
	const OFF = 0, STARTING = 1, LIVE = 2, FAILED = 3;

	const canShare = () =>
		!!(navigator.mediaDevices && navigator.mediaDevices.getDisplayMedia &&
			window.VideoEncoder && window.VideoFrame);
	const canWatch = () => !!(window.VideoDecoder && window.EncodedVideoChunk);

	// What can be watched, as bits (1 << codec); H.264 always, the others
	// once the browser has said it decodes them.
	let decodable = 1 << H264;
	if (canWatch() && VideoDecoder.isConfigSupported) {
		for (const [codec, name] of Object.entries(OTHER_CODECS)) {
			VideoDecoder.isConfigSupported({ codec: name, optimizeForLatency: true })
				.then((support) => { if (support.supported) decodable |= 1 << codec; })
				.catch(() => {});
		}
	}

	/* ---- sharing ---- */

	const share = {
		state: OFF,
		generation: 0, // bumped by stop, so a start still underway knows to give up
		stream: null,
		cancelGesture: null, // while the picker waits for a click (displayMedia)
		reader: null, // MediaStreamTrackProcessor's
		video: null, // or a <video> of the stream
		ticker: null, // and what samples it
		codec: null,
		encoder: null,
		width: 0,
		height: 0,
		canvas: null,
		context: null,
		queue: [],
		wantKey: true,
		awaitKey: false, // frames were dropped here; only a keyframe may follow
		lastKey: 0,
		lastFrame: -Infinity,
		audio: null, // { context, source, node } while audio is shared
		audioQueue: [], // Float32Arrays, interleaved stereo
		audioQueued: 0, // samples in audioQueue
	};

	async function start() {
		if (share.state === STARTING || share.state === LIVE) return;
		if (!canShare()) {
			share.state = FAILED;
			return;
		}
		share.state = STARTING;
		const generation = ++share.generation;
		const current = () => generation === share.generation;

		let stream;
		try {
			stream = await displayMedia();
		} catch (e) {
			// Cancelling the browser's picker is a NotAllowedError, and no
			// failure; neither is stop while waiting for a gesture (AbortError).
			if (current()) {
				console.warn("yap: nothing to share:", e);
				share.state = e && e.name === "NotAllowedError" ? OFF : FAILED;
			}
			return;
		}
		const track = stream.getVideoTracks()[0];
		const codec = track ? await pickCodec() : null;
		if (!current() || !codec) {
			stream.getTracks().forEach((t) => t.stop());
			if (current()) {
				console.warn("yap: this browser can't encode H.264");
				share.state = FAILED;
			}
			return;
		}

		// A screen is text and edges more than motion.
		try { track.contentHint = "detail"; } catch (e) {}
		track.addEventListener("ended", () => { if (current()) stop(OFF); });
		share.stream = stream;
		share.codec = codec;
		share.wantKey = true;
		share.awaitKey = false;
		share.lastFrame = -Infinity;
		if (typeof OffscreenCanvas === "function") {
			share.canvas = new OffscreenCanvas(2, 2);
		} else {
			share.canvas = document.createElement("canvas");
		}
		share.context = share.canvas.getContext("2d", { alpha: false });

		if (typeof MediaStreamTrackProcessor === "function") {
			share.reader = new MediaStreamTrackProcessor({ track }).readable.getReader();
			pump(share.reader, current);
		} else {
			const video = document.createElement("video");
			video.muted = true;
			video.playsInline = true;
			video.srcObject = stream;
			video.play().catch((e) => console.warn("yap: can't play the capture:", e));
			share.video = video;
			share.ticker = ticker(1000 / FPS, () => {
				if (video.readyState >= 2) capture(video, video.videoWidth, video.videoHeight);
			});
		}
		const audioTrack = stream.getAudioTracks()[0];
		if (audioTrack) startAudio(audioTrack, current);
		share.state = LIVE;
	}

	// The AudioWorklet: hands over what it's given in 10 ms chunks of
	// interleaved stereo (the node mixes a mono track up to two channels).
	const AUDIO_WORKLET = `
		class YapShareAudio extends AudioWorkletProcessor {
			constructor() {
				super();
				this.chunk = new Float32Array(${(AUDIO_RATE / 100) * 2});
				this.n = 0;
			}
			process(inputs) {
				const input = inputs[0];
				if (input && input.length) {
					const left = input[0], right = input[1] || input[0];
					for (let i = 0; i < left.length; i++) {
						this.chunk[this.n++] = left[i];
						this.chunk[this.n++] = right[i];
						if (this.n === this.chunk.length) {
							// Handed over, which leaves this.chunk empty.
							this.port.postMessage(this.chunk, [this.chunk.buffer]);
							this.chunk = new Float32Array(${(AUDIO_RATE / 100) * 2});
							this.n = 0;
						}
					}
				}
				return true;
			}
		}
		registerProcessor("yap-share-audio", YapShareAudio);
	`;

	// startAudio feeds the shared audio into share.audioQueue. Without it the
	// share goes on as a picture alone.
	async function startAudio(track, current) {
		let context;
		try {
			context = new AudioContext({ sampleRate: AUDIO_RATE, latencyHint: "interactive" });
			const url = URL.createObjectURL(new Blob([AUDIO_WORKLET], { type: "text/javascript" }));
			try {
				await context.audioWorklet.addModule(url);
			} finally {
				URL.revokeObjectURL(url);
			}
			if (!current()) {
				context.close().catch(() => {});
				return;
			}
			const source = context.createMediaStreamSource(new MediaStream([track]));
			const node = new AudioWorkletNode(context, "yap-share-audio", {
				numberOfInputs: 1,
				numberOfOutputs: 1,
				channelCount: 2,
				channelCountMode: "explicit",
			});
			node.port.onmessage = (e) => queueAudio(e.data);
			source.connect(node);
			// Silent, but it keeps the node running.
			node.connect(context.destination);
			// Set before waiting again, so stop closes it from here on.
			share.audio = { context, source, node };
			context = null;
			if (share.audio.context.state !== "running") await share.audio.context.resume();
			console.info("yap: sharing audio too");
		} catch (e) {
			console.warn("yap: can't share the audio:", e);
			if (context) context.close().catch(() => {});
		}
	}

	function queueAudio(samples) {
		share.audioQueue.push(samples);
		share.audioQueued += samples.length;
		while (share.audioQueued > MAX_AUDIO_QUEUED) {
			share.audioQueued -= share.audioQueue.shift().length;
		}
	}

	// pullAudio takes up to `max` samples (a whole number of stereo frames)
	// from the queue, or returns null if there are none.
	function pullAudio(max) {
		max -= max % 2;
		if (!share.audioQueued || max <= 0) return null;
		const out = new Float32Array(Math.min(max, share.audioQueued));
		let n = 0;
		while (n < out.length) {
			const head = share.audioQueue[0];
			const take = Math.min(head.length, out.length - n);
			out.set(take === head.length ? head : head.subarray(0, take), n);
			n += take;
			if (take === head.length) share.audioQueue.shift();
			else share.audioQueue[0] = head.subarray(take);
		}
		share.audioQueued -= n;
		return out;
	}

	function stopAudio() {
		const a = share.audio;
		if (a) {
			a.node.port.onmessage = null;
			a.source.disconnect();
			a.node.disconnect();
			a.context.close().catch(() => {});
		}
		share.audio = null;
		share.audioQueue = [];
		share.audioQueued = 0;
	}

	/*
	displayMedia opens the browser's picker. The client acts on a click a
	frame after it, from its own loop, which most browsers take for the
	click (they allow a few seconds after one). Safari only opens it from
	inside the handler of a click or key, and fails with an
	InvalidStateError; then it's asked again from the handler of the next
	release - the client's buttons go on the press, so that's normally the
	release of the same click.
	*/
	function displayMedia() {
		const ask = () => askDisplayMedia(true).catch((e) => {
			// The audio couldn't be started (Chromium, with no audio
			// service), which fails the picture too. Better without it.
			if (!e || e.name !== "NotReadableError") throw e;
			console.warn("yap: sharing without audio:", e);
			return askDisplayMedia(false);
		});
		return ask().catch((e) => {
			if (!e || e.name !== "InvalidStateError") throw e;
			return new Promise((resolve, reject) => {
				const types = ["mouseup", "pointerup", "touchend", "keyup"];
				const done = () => {
					for (const type of types) window.removeEventListener(type, go, true);
					share.cancelGesture = null;
				};
				const go = () => {
					done();
					ask().then(resolve, reject);
				};
				for (const type of types) window.addEventListener(type, go, true);
				share.cancelGesture = () => {
					done();
					reject(new DOMException("Sharing was stopped", "AbortError"));
				};
			});
		});
	}

	function askDisplayMedia(audio) {
		return navigator.mediaDevices.getDisplayMedia({
			video: { frameRate: { ideal: FPS, max: 30 } },
			// Never our own page's sound (the others' voices). Turning off
			// echo cancellation and the like as well made Chromium fail to
			// start the audio at all (headless, 153).
			audio: audio ? { restrictOwnAudio: true, echoCancellation: 'false', noiseSuppression: 'false' } : false,
			// Offer the whole system's audio with a screen, where the
			// browser can (Chromium on Windows).
			systemAudio: audio ? "include" : "exclude",
		});
	}

	async function pump(reader, current) {
		while (current()) {
			let result;
			try {
				result = await reader.read();
			} catch (e) {
				break;
			}
			if (result.done) break;
			const frame = result.value;
			try {
				if (current()) capture(frame, frame.displayWidth, frame.displayHeight);
			} finally {
				frame.close();
			}
		}
	}

	async function pickCodec() {
		for (const codec of H264_CODECS) {
			try {
				const support = await VideoEncoder.isConfigSupported(encoderConfig(codec, 1920, 1080));
				if (support.supported) return codec;
			} catch (e) {}
		}
		return null;
	}

	function encoderConfig(codec, width, height) {
		return {
			codec,
			width,
			height,
			bitrate: BITRATE,
			framerate: FPS,
			latencyMode: "realtime",
			avc: { format: "annexb" },
		};
	}

	// fit scales a size down to MAX_LONG_SIDE by MAX_SHORT_SIDE (either
	// way round), in the even numbers H.264 wants.
	function fit(width, height) {
		const scale = Math.min(
			1,
			MAX_LONG_SIDE / Math.max(width, height),
			MAX_SHORT_SIDE / Math.min(width, height),
		);
		const even = (n) => Math.max(2, Math.round((n * scale) / 2) * 2);
		return [even(width), even(height)];
	}

	// capture takes a frame of the screen, if one is due, and encodes it.
	function capture(source, width, height) {
		const now = performance.now();
		// A little slack, so a source at exactly FPS isn't halved.
		if (now - share.lastFrame < 1000 / FPS - 3 || !width || !height) return;
		const [w, h] = fit(width, height);
		if (w !== share.width || h !== share.height || !share.encoder) {
			// Also when a shared window changes size.
			if (!configure(w, h)) return;
		}
		const encoder = share.encoder;
		if (encoder.state !== "configured" || encoder.encodeQueueSize > 2) return;
		share.lastFrame = now;

		share.context.drawImage(source, 0, 0, w, h);
		const frame = new VideoFrame(share.canvas, { timestamp: Math.round(now * 1000) });
		const key = share.wantKey || now - share.lastKey >= KEY_INTERVAL_MS;
		if (key) {
			share.wantKey = false;
			share.lastKey = now;
		}
		try {
			encoder.encode(frame, { keyFrame: key });
		} finally {
			frame.close();
		}
	}

	function configure(width, height) {
		try {
			if (!share.encoder) {
				share.encoder = new VideoEncoder({
					output: encoded,
					error: (e) => {
						console.warn("yap: the encoder failed:", e);
						stop(FAILED);
					},
				});
			}
			share.encoder.configure(encoderConfig(share.codec, width, height));
		} catch (e) {
			console.warn("yap: can't encode " + width + "x" + height + ":", e);
			stop(FAILED);
			return false;
		}
		share.width = share.canvas.width = width;
		share.height = share.canvas.height = height;
		share.wantKey = true;
		return true;
	}

	function encoded(chunk) {
		if (share.state !== LIVE) return;
		const key = chunk.type === "key";
		if (share.queue.length >= MAX_QUEUED) {
			// The client isn't taking them. What's queued goes, and with it
			// anything that depends on it.
			share.queue.length = 0;
			share.awaitKey = true;
			share.wantKey = true;
		}
		if (share.awaitKey && !key) return;
		share.awaitKey = false;
		const data = new Uint8Array(chunk.byteLength);
		chunk.copyTo(data);
		share.queue.push({ data, ts: Math.round(chunk.timestamp / 1000) >>> 0, key });
	}

	function stop(state) {
		share.generation++;
		if (share.cancelGesture) share.cancelGesture();
		if (share.reader) share.reader.cancel().catch(() => {});
		if (share.ticker) share.ticker.stop();
		if (share.video) share.video.srcObject = null;
		if (share.stream) share.stream.getTracks().forEach((t) => t.stop());
		if (share.encoder && share.encoder.state !== "closed") share.encoder.close();
		stopAudio();
		Object.assign(share, {
			stream: null, reader: null, video: null, ticker: null, encoder: null,
			canvas: null, context: null, width: 0, height: 0, queue: [],
		});
		share.state = state;
	}

	/*
	ticker calls fn every `ms` from a worker's timer, which a hidden tab
	doesn't hold back the way it does its own (see web/background.js).
	*/
	function ticker(ms, fn) {
		try {
			const source = `setInterval(() => postMessage(0), ${ms});`;
			const url = URL.createObjectURL(new Blob([source], { type: "text/javascript" }));
			const worker = new Worker(url);
			URL.revokeObjectURL(url);
			worker.onmessage = fn;
			return { stop: () => worker.terminate() };
		} catch (e) {
			const id = setInterval(fn, ms);
			return { stop: () => clearInterval(id) };
		}
	}

	/* ---- watching ---- */

	const watch = {
		sharer: 0,
		codec: H264, // what the decoder is set up for
		decoder: null,
		failed: false,
		latest: null, // the newest decoded frame, not yet drawn
		frames: 0, // decoded, for tests
	};

	function show(sharer, data, ts, key, codec) {
		if (!canWatch() || !(decodable & (1 << codec))) return;
		if (sharer !== watch.sharer) end();
		watch.sharer = sharer;
		if (codec !== watch.codec && watch.decoder) {
			// The sharer changed encoder; a keyframe starts the new one.
			if (watch.decoder.state !== "closed") watch.decoder.close();
			watch.decoder = null;
		}
		watch.codec = codec;
		if (!watch.decoder) {
			if (!key) return;
			watch.decoder = new VideoDecoder({
				output: draw,
				error: (e) => {
					console.warn("yap: the decoder failed:", e);
					fail();
				},
			});
		}
		const decoder = watch.decoder;
		try {
			if (decoder.state !== "configured") {
				if (!key) return;
				const name = codec === H264 ? h264Codec(data) || H264_CODECS[0] : OTHER_CODECS[codec];
				decoder.configure({ codec: name, optimizeForLatency: true });
			}
			if (decoder.decodeQueueSize > MAX_DECODING) {
				fail();
				return;
			}
			decoder.decode(new EncodedVideoChunk({ type: key ? "key" : "delta", timestamp: ts * 1000, data }));
		} catch (e) {
			console.warn("yap: can't decode:", e);
			fail();
		}
	}

	function draw(frame) {
		if (watch.latest) watch.latest.close();
		watch.latest = frame;
		watch.frames++;
	}

	// fail drops the decoder; the next keyframe starts a new one.
	function fail() {
		watch.failed = true;
		if (watch.decoder && watch.decoder.state !== "closed") watch.decoder.close();
		watch.decoder = null;
	}

	// end forgets whoever we were watching.
	function end() {
		if (watch.decoder && watch.decoder.state !== "closed") watch.decoder.close();
		watch.decoder = null;
		watch.sharer = 0;
		watch.failed = false;
		if (watch.latest) watch.latest.close();
		watch.latest = null;
	}

	/*
	h264Codec reads the codec string ("avc1.PPCCLL") out of the sequence
	parameter set a keyframe starts with, so the decoder is set up for
	whichever profile the sharer's browser chose.
	*/
	function h264Codec(data) {
		for (let i = 0; i + 6 < data.length; i++) {
			if (data[i] !== 0 || data[i + 1] !== 0 || data[i + 2] !== 1) continue;
			if ((data[i + 3] & 0x1f) === 7) {
				const hex = (b) => b.toString(16).toUpperCase().padStart(2, "0");
				return "avc1." + hex(data[i + 4]) + hex(data[i + 5]) + hex(data[i + 6]);
			}
			i += 2;
		}
		return null;
	}

	/*
	The page goes fullscreen, not just the picture, since the client draws
	it. `wanted` is true from asking until fullscreen ends (Escape, or
	setFullscreen(false)), so the client doesn't take the moment before
	the browser has done it for fullscreen having ended.
	*/
	const full = { wanted: false };
	document.addEventListener("fullscreenchange", () => {
		if (!document.fullscreenElement) full.wanted = false;
	});

	function setFullscreen(on) {
		const page = document.documentElement;
		if (on && !full.wanted && page.requestFullscreen) {
			full.wanted = true;
			page.requestFullscreen().catch((e) => {
				console.warn("yap: no fullscreen:", e);
				full.wanted = false;
			});
		} else if (!on) {
			full.wanted = false;
			if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
		}
	}

	Module.yapVideo = {
		canShare,
		canWatch,
		decodable: () => decodable,
		start,
		stop: () => stop(OFF),
		state: () => share.state,
		live: () => share.state === LIVE,
		nextSize: () => (share.queue.length ? share.queue[0].data.length : -1),
		pull: () => share.queue.shift() || null,
		requestKey: () => { share.wantKey = true; },
		audioLive: () => share.state === LIVE && !!share.audio,
		pullAudio,
		show,
		end,
		takeError: () => {
			const failed = watch.failed;
			watch.failed = false;
			return failed;
		},
		// The newest decoded frame, which the caller then owns (and closes).
		takeFrame: () => {
			const frame = watch.latest;
			watch.latest = null;
			return frame;
		},
		setFullscreen,
		isFullscreen: () => full.wanted,
		// For tests: how many frames have been decoded.
		framesShown: () => watch.frames,
	};
})();
