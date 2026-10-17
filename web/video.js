/*
Screen sharing, the browser's half (emcc --pre-js, see web/build.sh): it
captures the screen and encodes it, and decodes and shows what somebody
else shares. The client carries the encoded frames (src/client/video.odin)
and reaches this through Module.yapVideo (web/shell.c).

Sharing: getDisplayMedia's track is scaled to fit the size the client
asks for (its share settings), sampled at its frame rate and encoded as
H.264 at its bitrate (Annex B, so every keyframe carries what the decoder
needs to start). The client lowers the bitrate when its viewers can't keep
up (setBitrate), which starts the encoder again at a keyframe. Encoded frames wait in a queue until the client
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
	const KEY_INTERVAL_MS = 5000;
	// Frames the client hasn't pulled; more means it isn't running.
	const MAX_QUEUED = 30;
	// Frames waiting in the decoder; more means it can't keep up.
	const MAX_DECODING = 30;
	// Shared audio the client hasn't pulled, in samples (interleaved
	// stereo at 48 kHz): half a second. Older audio is dropped.
	const AUDIO_RATE = 48000;
	const MAX_AUDIO_QUEUED = AUDIO_RATE;
	// Constrained Baseline, Main, High, at level 4 (1080p30): for watching
	// when a keyframe doesn't say, and a sharer's level is chosen by its size
	// and frame rate (h264Level).
	const H264_CODECS = ["avc1.42E028", "avc1.4D0028", "avc1.640028"];
	// H.264's levels from 4 up: the most macroblocks a second and in a
	// frame each allows.
	const H264_LEVELS = [
		[0x28, 245760, 8192], // 4: 1080p30
		[0x2a, 522240, 8704], // 4.2: 1080p60
		[0x32, 589824, 22080], // 5: 1440p30
		[0x33, 983040, 36864], // 5.1: 2160p30
		[0x34, 2073600, 36864], // 5.2: 2160p60
		[0x3c, 4177920, 139264], // 6
		[0x3e, 16711680, 139264], // 6.2
	];
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
		// What the client asked for (start): frames a second, the bitrate
		// adapting never goes above (bits a second), and the largest size
		// (0 keeps the screen's own). `bitrate` is what it encodes at now.
		fps: 30,
		maxBitrate: 0,
		bitrate: 0,
		maxWidth: 0,
		maxHeight: 0,
		audio: null, // { context, source, node } while audio is shared
		audioQueue: [], // Float32Arrays, interleaved stereo
		audioQueued: 0, // samples in audioQueue
	};

	async function start(fps, kbit, maxWidth, maxHeight) {
		if (share.state === STARTING || share.state === LIVE) return;
		Object.assign(share, {
			fps: Math.max(1, fps),
			maxBitrate: kbit * 1000,
			bitrate: kbit * 1000,
			maxWidth,
			maxHeight,
		});
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
		let codec = null;
		if (track) {
			const { width = 1920, height = 1080 } = track.getSettings();
			codec = await pickCodec(...fit(width, height));
		}
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
			share.ticker = ticker(1000 / share.fps, () => {
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
		// If the audio can't be started (as headless Chromium can't
		// without echo cancellation), the picture fails too: then it's asked
		// again with less, opening the picker again.
		const ask = (audio = AUDIO_UNPROCESSED) => askDisplayMedia(audio).catch((e) => {
			if (!e || e.name !== "NotReadableError" || !audio) throw e;
			const less = audio === AUDIO_UNPROCESSED ? AUDIO_ECHO_CANCELLED : null;
			console.warn("yap: sharing " + (less ? "with echo cancellation" : "without audio") + ":", e);
			return ask(less);
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

	/*
	The shared audio as it plays: Chromium otherwise treats it like a
	microphone (echo cancellation, noise suppression and automatic gain, all
	on), which muffles it and makes it pump when it goes quiet. Echo
	cancellation can only be chosen when the track starts (applyConstraints
	refuses it later). Never our own page's sound (the others' voices).
	*/
	const AUDIO_UNPROCESSED = {
		restrictOwnAudio: true,
		echoCancellation: false,
		noiseSuppression: false,
		autoGainControl: false,
	};
	const AUDIO_ECHO_CANCELLED = { ...AUDIO_UNPROCESSED, echoCancellation: true };

	// askDisplayMedia opens the picker, for audio as `audio` says (null:
	// none).
	function askDisplayMedia(audio) {
		return navigator.mediaDevices.getDisplayMedia({
			video: { frameRate: { ideal: share.fps, max: share.fps } },
			audio: audio || false,
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

	// pickCodec returns the first H.264 profile the browser encodes at this
	// size, as "avc1.PPCC" (the level is added by encoderConfig).
	async function pickCodec(width, height) {
		for (const codec of H264_CODECS) {
			const profile = codec.slice(0, 9);
			try {
				const support = await VideoEncoder.isConfigSupported(encoderConfig(profile, width, height));
				if (support.supported) return profile;
			} catch (e) {}
		}
		return null;
	}

	// h264Level is the lowest level (as two hex digits) that takes this size
	// at the share's frame rate. A level below it makes encoders fail.
	function h264Level(width, height) {
		const frame = Math.ceil(width / 16) * Math.ceil(height / 16);
		const rate = frame * share.fps;
		const level =
			H264_LEVELS.find(([, maxRate, maxFrame]) => rate <= maxRate && frame <= maxFrame) ||
			H264_LEVELS[H264_LEVELS.length - 1];
		return level[0].toString(16).toUpperCase().padStart(2, "0");
	}

	function encoderConfig(profile, width, height) {
		return {
			codec: profile + h264Level(width, height),
			width,
			height,
			bitrate: share.bitrate,
			framerate: share.fps,
			latencyMode: "realtime",
			avc: { format: "annexb" },
		};
	}

	// fit scales a size down to the largest the client asked for (either
	// way round), in the even numbers H.264 wants.
	function fit(width, height) {
		const long = Math.max(share.maxWidth, share.maxHeight);
		const short = Math.min(share.maxWidth, share.maxHeight);
		const scale = long > 0 && short > 0
			? Math.min(1, long / Math.max(width, height), short / Math.min(width, height))
			: 1;
		const even = (n) => Math.max(2, Math.round((n * scale) / 2) * 2);
		return [even(width), even(height)];
	}

	// capture takes a frame of the screen, if one is due, and encodes it.
	function capture(source, width, height) {
		const now = performance.now();
		// A little slack, so a source at exactly the frame rate isn't halved.
		if (now - share.lastFrame < 1000 / share.fps - 3 || !width || !height) return;
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

	// setBitrate has the encoder make `kbit` from its next frame, which is a
	// keyframe (configure). The client asks only now and then for this reason.
	function setBitrate(kbit) {
		const bitrate = Math.min(kbit * 1000, share.maxBitrate);
		if (share.state !== LIVE || bitrate <= 0 || bitrate === share.bitrate) return;
		share.bitrate = bitrate;
		if (share.encoder && share.width) configure(share.width, share.height);
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
		setBitrate,
		// What it encodes at now, and what it was asked to, in kbit/s; 0
		// while it isn't sharing.
		encodingKbit: () => (share.state === LIVE ? Math.round(share.bitrate / 1000) : 0),
		maxKbit: () => (share.state === LIVE ? Math.round(share.maxBitrate / 1000) : 0),
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
