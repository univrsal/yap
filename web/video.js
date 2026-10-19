/*
Screen sharing and the camera, the browser's half (emcc --pre-js, see
web/build.sh): it captures the screen and the camera and encodes them, and
decodes and shows what others share. The client carries the encoded frames
(src/client/conn/video.odin) and reaches this through Module.yapVideo
(web/shell.c). Streams are numbered as in src/common/proto/video.odin: 0 the
screen, 1 the camera.

Sharing: getDisplayMedia's track (the screen) or getUserMedia's (the
camera) is scaled to fit the size the client asks for, sampled at its
frame rate and encoded as H.264 at its bitrate (Annex B, so every keyframe
carries what the decoder needs to start). Each has a capture of its own
(screen, camera) with its own encoder. The client lowers the bitrate when
its viewers can't keep up (setBitrate), which starts the encoder again at a
keyframe. Encoded frames wait in a queue until the client pulls them. The
frames come from a MediaStreamTrackProcessor where there is one, otherwise
from a <video> playing the stream, sampled from a worker's timer - either
keeps going when this tab is hidden, which it usually is while another tab
is being shared. The camera's newest frame, as it is encoded, is also kept
for the self view (takePreview); it isn't mirrored here.

Where the browser shares audio with the screen (Chromium: a tab's, or on
Windows the whole system's along with a screen), an AudioWorklet takes it at
48 kHz stereo and it waits in a queue until the client pulls it, to send
mixed into our voice like a shared application's (src/client/conn/video_web.odin).
restrictOwnAudio leaves out what this page plays, so nobody hears
themselves back.

Watching: each stream watched (a sharer's screen or camera) has a
VideoDecoder of its own - H.264, and HEVC and AV1 where the browser takes
them (decodable, which the client tells the others so their shares keep to
it) - and its newest decoded frame waits until the client draws it, which it
does in its own canvas as a texture (takeFrame, yap_video_upload in
web/shell.c) - older ones are let go unseen. A decoder that fails says so
through takeError, and the client asks for a new keyframe. Fullscreen is the
whole page's; the client then shows nothing but the picture.

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

	const canEncode = () => !!(window.VideoEncoder && window.VideoFrame);
	const canShare = () =>
		!!(navigator.mediaDevices && navigator.mediaDevices.getDisplayMedia && canEncode());
	const canCamera = () =>
		!!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia && canEncode());
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

	// newCapture makes what a capture keeps: the screen's, or the camera's.
	const newCapture = (camera) => ({
		camera,
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
		// (0 keeps the source's own). `bitrate` is what it encodes at now.
		fps: 30,
		maxBitrate: 0,
		bitrate: 0,
		maxWidth: 0,
		maxHeight: 0,
		audio: null, // { context, source, node } while audio is shared (the screen's)
		audioQueue: [], // Float32Arrays, interleaved stereo
		audioQueued: 0, // samples in audioQueue
		preview: null, // the camera's newest frame, not yet drawn (takePreview)
	});
	const screen = newCapture(false);
	const camera = newCapture(true);
	// By stream number.
	const captures = [screen, camera];
	const captureOf = (stream) => captures[stream] || screen;

	// start shares the screen, asking the browser's picker what.
	function start(fps, kbit, maxWidth, maxHeight) {
		if (!canShare()) {
			screen.state = FAILED;
			return;
		}
		begin(screen, fps, kbit, maxWidth, maxHeight, () => displayMedia());
	}

	// startCamera turns on the camera `device` (a deviceId; "" for the
	// browser's choice, a phone's front camera).
	function startCamera(fps, kbit, maxWidth, maxHeight, device) {
		if (!canCamera()) {
			camera.state = FAILED;
			return;
		}
		begin(camera, fps, kbit, maxWidth, maxHeight, () => userMedia(device));
	}

	async function begin(s, fps, kbit, maxWidth, maxHeight, open) {
		if (s.state === STARTING || s.state === LIVE) return;
		Object.assign(s, {
			fps: Math.max(1, fps),
			maxBitrate: kbit * 1000,
			bitrate: kbit * 1000,
			maxWidth,
			maxHeight,
		});
		s.state = STARTING;
		const generation = ++s.generation;
		const current = () => generation === s.generation;

		let stream;
		try {
			stream = await open();
		} catch (e) {
			// Cancelling the browser's picker is a NotAllowedError, and no
			// failure; neither is stop while waiting for a gesture (AbortError).
			// A camera that isn't allowed is one.
			if (current()) {
				console.warn("yap: nothing to " + (s.camera ? "show:" : "share:"), e);
				s.state = e && e.name === "NotAllowedError" && !s.camera ? OFF : FAILED;
			}
			return;
		}
		const track = stream.getVideoTracks()[0];
		let codec = null;
		if (track) {
			const { width = 1920, height = 1080 } = track.getSettings();
			codec = await pickCodec(s, ...fit(s, width, height));
		}
		if (!current() || !codec) {
			stream.getTracks().forEach((t) => t.stop());
			if (current()) {
				console.warn("yap: this browser can't encode H.264");
				s.state = FAILED;
			}
			return;
		}

		// A screen is text and edges more than motion, a camera the other
		// way round.
		try { track.contentHint = s.camera ? "motion" : "detail"; } catch (e) {}
		track.addEventListener("ended", () => { if (current()) stop(s, OFF); });
		s.stream = stream;
		s.codec = codec;
		s.wantKey = true;
		s.awaitKey = false;
		s.lastFrame = -Infinity;
		if (typeof OffscreenCanvas === "function") {
			s.canvas = new OffscreenCanvas(2, 2);
		} else {
			s.canvas = document.createElement("canvas");
		}
		s.context = s.canvas.getContext("2d", { alpha: false });

		if (typeof MediaStreamTrackProcessor === "function") {
			s.reader = new MediaStreamTrackProcessor({ track }).readable.getReader();
			pump(s, s.reader, current);
		} else {
			const video = document.createElement("video");
			video.muted = true;
			video.playsInline = true;
			video.srcObject = stream;
			video.play().catch((e) => console.warn("yap: can't play the capture:", e));
			s.video = video;
			s.ticker = ticker(1000 / s.fps, () => {
				if (video.readyState >= 2) capture(s, video, video.videoWidth, video.videoHeight);
			});
		}
		const audioTrack = stream.getAudioTracks()[0];
		if (audioTrack && !s.camera) startAudio(audioTrack, current);
		s.state = LIVE;
	}

	// userMedia asks for the camera, as big as the client asked for at most.
	function userMedia(device) {
		const video = {
			frameRate: { ideal: camera.fps, max: camera.fps },
			width: { ideal: camera.maxWidth || 1280 },
			height: { ideal: camera.maxHeight || 720 },
		};
		if (device) video.deviceId = { exact: device };
		else video.facingMode = "user";
		return navigator.mediaDevices.getUserMedia({ video, audio: false });
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

	// startAudio feeds the shared audio into screen.audioQueue. Without it the
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
			screen.audio = { context, source, node };
			context = null;
			if (screen.audio.context.state !== "running") await screen.audio.context.resume();
			console.info("yap: sharing audio too");
		} catch (e) {
			console.warn("yap: can't share the audio:", e);
			if (context) context.close().catch(() => {});
		}
	}

	function queueAudio(samples) {
		screen.audioQueue.push(samples);
		screen.audioQueued += samples.length;
		while (screen.audioQueued > MAX_AUDIO_QUEUED) {
			screen.audioQueued -= screen.audioQueue.shift().length;
		}
	}

	// pullAudio takes up to `max` samples (a whole number of stereo frames)
	// from the queue, or returns null if there are none.
	function pullAudio(max) {
		max -= max % 2;
		if (!screen.audioQueued || max <= 0) return null;
		const out = new Float32Array(Math.min(max, screen.audioQueued));
		let n = 0;
		while (n < out.length) {
			const head = screen.audioQueue[0];
			const take = Math.min(head.length, out.length - n);
			out.set(take === head.length ? head : head.subarray(0, take), n);
			n += take;
			if (take === head.length) screen.audioQueue.shift();
			else screen.audioQueue[0] = head.subarray(take);
		}
		screen.audioQueued -= n;
		return out;
	}

	function stopAudio() {
		const a = screen.audio;
		if (a) {
			a.node.port.onmessage = null;
			a.source.disconnect();
			a.node.disconnect();
			a.context.close().catch(() => {});
		}
		screen.audio = null;
		screen.audioQueue = [];
		screen.audioQueued = 0;
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
					screen.cancelGesture = null;
				};
				const go = () => {
					done();
					ask().then(resolve, reject);
				};
				for (const type of types) window.addEventListener(type, go, true);
				screen.cancelGesture = () => {
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
			video: { frameRate: { ideal: screen.fps, max: screen.fps } },
			audio: audio || false,
			// Offer the whole system's audio with a screen, where the
			// browser can (Chromium on Windows).
			systemAudio: audio ? "include" : "exclude",
		});
	}

	async function pump(s, reader, current) {
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
				if (current()) capture(s, frame, frame.displayWidth, frame.displayHeight);
			} finally {
				frame.close();
			}
		}
	}

	// pickCodec returns the first H.264 profile the browser encodes at this
	// size, as "avc1.PPCC" (the level is added by encoderConfig).
	async function pickCodec(s, width, height) {
		for (const codec of H264_CODECS) {
			const profile = codec.slice(0, 9);
			try {
				const support = await VideoEncoder.isConfigSupported(encoderConfig(s, profile, width, height));
				if (support.supported) return profile;
			} catch (e) {}
		}
		return null;
	}

	// h264Level is the lowest level (as two hex digits) that takes this size
	// at the capture's frame rate. A level below it makes encoders fail.
	function h264Level(s, width, height) {
		const frame = Math.ceil(width / 16) * Math.ceil(height / 16);
		const rate = frame * s.fps;
		const level =
			H264_LEVELS.find(([, maxRate, maxFrame]) => rate <= maxRate && frame <= maxFrame) ||
			H264_LEVELS[H264_LEVELS.length - 1];
		return level[0].toString(16).toUpperCase().padStart(2, "0");
	}

	function encoderConfig(s, profile, width, height) {
		return {
			codec: profile + h264Level(s, width, height),
			width,
			height,
			bitrate: s.bitrate,
			framerate: s.fps,
			latencyMode: "realtime",
			avc: { format: "annexb" },
		};
	}

	// fit scales a size down to the largest the client asked for (either
	// way round), in the even numbers H.264 wants.
	function fit(s, width, height) {
		const long = Math.max(s.maxWidth, s.maxHeight);
		const short = Math.min(s.maxWidth, s.maxHeight);
		const scale = long > 0 && short > 0
			? Math.min(1, long / Math.max(width, height), short / Math.min(width, height))
			: 1;
		const even = (n) => Math.max(2, Math.round((n * scale) / 2) * 2);
		return [even(width), even(height)];
	}

	// capture takes a frame of the screen or camera, if one is due, and
	// encodes it.
	function capture(s, source, width, height) {
		const now = performance.now();
		// A little slack, so a source at exactly the frame rate isn't halved.
		if (now - s.lastFrame < 1000 / s.fps - 3 || !width || !height) return;
		const [w, h] = fit(s, width, height);
		if (w !== s.width || h !== s.height || !s.encoder) {
			// Also when a shared window changes size.
			if (!configure(s, w, h)) return;
		}
		const encoder = s.encoder;
		if (encoder.state !== "configured" || encoder.encodeQueueSize > 2) return;
		s.lastFrame = now;

		s.context.drawImage(source, 0, 0, w, h);
		const frame = new VideoFrame(s.canvas, { timestamp: Math.round(now * 1000) });
		const key = s.wantKey || now - s.lastKey >= KEY_INTERVAL_MS;
		if (key) {
			s.wantKey = false;
			s.lastKey = now;
		}
		try {
			if (s.camera) {
				if (s.preview) s.preview.close();
				s.preview = frame.clone();
			}
			encoder.encode(frame, { keyFrame: key });
		} finally {
			frame.close();
		}
	}

	function configure(s, width, height) {
		try {
			if (!s.encoder) {
				s.encoder = new VideoEncoder({
					output: (chunk) => encoded(s, chunk),
					error: (e) => {
						console.warn("yap: the encoder failed:", e);
						stop(s, FAILED);
					},
				});
			}
			s.encoder.configure(encoderConfig(s, s.codec, width, height));
		} catch (e) {
			console.warn("yap: can't encode " + width + "x" + height + ":", e);
			stop(s, FAILED);
			return false;
		}
		s.width = s.canvas.width = width;
		s.height = s.canvas.height = height;
		s.wantKey = true;
		return true;
	}

	function encoded(s, chunk) {
		if (s.state !== LIVE) return;
		const key = chunk.type === "key";
		if (s.queue.length >= MAX_QUEUED) {
			// The client isn't taking them. What's queued goes, and with it
			// anything that depends on it.
			s.queue.length = 0;
			s.awaitKey = true;
			s.wantKey = true;
		}
		if (s.awaitKey && !key) return;
		s.awaitKey = false;
		const data = new Uint8Array(chunk.byteLength);
		chunk.copyTo(data);
		s.queue.push({ data, ts: Math.round(chunk.timestamp / 1000) >>> 0, key });
	}

	// setBitrate has the encoder make `kbit` from its next frame, which is a
	// keyframe (configure). The client asks only now and then for this reason.
	function setBitrate(s, kbit) {
		const bitrate = Math.min(kbit * 1000, s.maxBitrate);
		if (s.state !== LIVE || bitrate <= 0 || bitrate === s.bitrate) return;
		s.bitrate = bitrate;
		if (s.encoder && s.width) configure(s, s.width, s.height);
	}

	function stop(s, state) {
		s.generation++;
		if (s.cancelGesture) s.cancelGesture();
		if (s.reader) s.reader.cancel().catch(() => {});
		if (s.ticker) s.ticker.stop();
		if (s.video) s.video.srcObject = null;
		if (s.stream) s.stream.getTracks().forEach((t) => t.stop());
		if (s.encoder && s.encoder.state !== "closed") s.encoder.close();
		if (s.preview) s.preview.close();
		if (!s.camera) stopAudio();
		Object.assign(s, {
			stream: null, reader: null, video: null, ticker: null, encoder: null,
			canvas: null, context: null, width: 0, height: 0, queue: [], preview: null,
		});
		s.state = state;
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

	// The streams being decoded, by "sharer:stream": each with its decoder,
	// the codec it is set up for, whether it failed, its newest decoded frame
	// not yet drawn, and how many it decoded (for tests).
	const views = new Map();
	const viewKey = (sharer, stream) => sharer + ":" + stream;

	function show(sharer, stream, data, ts, key, codec) {
		if (!canWatch() || !(decodable & (1 << codec))) return;
		const id = viewKey(sharer, stream);
		let v = views.get(id);
		if (!v) {
			v = { codec, decoder: null, failed: false, latest: null, frames: 0 };
			views.set(id, v);
		}
		if (codec !== v.codec && v.decoder) {
			// The sharer changed encoder; a keyframe starts the new one.
			if (v.decoder.state !== "closed") v.decoder.close();
			v.decoder = null;
		}
		v.codec = codec;
		if (!v.decoder) {
			if (!key) return;
			v.decoder = new VideoDecoder({
				output: (frame) => draw(v, frame),
				error: (e) => {
					console.warn("yap: the decoder failed:", e);
					fail(v);
				},
			});
		}
		const decoder = v.decoder;
		try {
			if (decoder.state !== "configured") {
				if (!key) return;
				const name = codec === H264 ? h264Codec(data) || H264_CODECS[0] : OTHER_CODECS[codec];
				decoder.configure({ codec: name, optimizeForLatency: true });
			}
			if (decoder.decodeQueueSize > MAX_DECODING) {
				fail(v);
				return;
			}
			decoder.decode(new EncodedVideoChunk({ type: key ? "key" : "delta", timestamp: ts * 1000, data }));
		} catch (e) {
			console.warn("yap: can't decode:", e);
			fail(v);
		}
	}

	function draw(v, frame) {
		if (v.latest) v.latest.close();
		v.latest = frame;
		v.frames++;
	}

	// fail drops a decoder; the next keyframe starts a new one.
	function fail(v) {
		v.failed = true;
		if (v.decoder && v.decoder.state !== "closed") v.decoder.close();
		v.decoder = null;
	}

	// end forgets a stream we were watching.
	function end(sharer, stream) {
		const id = viewKey(sharer, stream);
		const v = views.get(id);
		if (!v) return;
		if (v.decoder && v.decoder.state !== "closed") v.decoder.close();
		if (v.latest) v.latest.close();
		views.delete(id);
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
		canCamera,
		canWatch,
		decodable: () => decodable,
		// The screen: start opens the browser's picker.
		start,
		startCamera,
		// The rest take the stream (0 the screen, 1 the camera).
		stop: (stream) => stop(captureOf(stream), OFF),
		state: (stream) => captureOf(stream).state,
		live: (stream) => captureOf(stream).state === LIVE,
		nextSize: (stream) => {
			const q = captureOf(stream).queue;
			return q.length ? q[0].data.length : -1;
		},
		pull: (stream) => captureOf(stream).queue.shift() || null,
		requestKey: (stream) => { captureOf(stream).wantKey = true; },
		setBitrate: (stream, kbit) => setBitrate(captureOf(stream), kbit),
		// What it encodes at now, and what it was asked to, in kbit/s; 0
		// while it isn't live.
		encodingKbit: (stream) => {
			const s = captureOf(stream);
			return s.state === LIVE ? Math.round(s.bitrate / 1000) : 0;
		},
		maxKbit: (stream) => {
			const s = captureOf(stream);
			return s.state === LIVE ? Math.round(s.maxBitrate / 1000) : 0;
		},
		audioLive: () => screen.state === LIVE && !!screen.audio,
		pullAudio,
		// The camera's newest frame as it was encoded, which the caller then
		// owns (and closes); null if none came since the last time.
		takePreview: () => {
			const frame = camera.preview;
			camera.preview = null;
			return frame;
		},
		show,
		end,
		takeError: (sharer, stream) => {
			const v = views.get(viewKey(sharer, stream));
			const failed = !!(v && v.failed);
			if (v) v.failed = false;
			return failed;
		},
		// A stream's newest decoded frame, which the caller then owns (and
		// closes).
		takeFrame: (sharer, stream) => {
			const v = views.get(viewKey(sharer, stream));
			const frame = v ? v.latest : null;
			if (v) v.latest = null;
			return frame;
		},
		setFullscreen,
		isFullscreen: () => full.wanted,
		// For tests: how many frames of a stream have been decoded.
		framesShown: (sharer, stream) => {
			const v = views.get(viewKey(sharer, stream));
			return v ? v.frames : 0;
		},
	};
})();
