/*
Screen sharing and the camera, the browser's half (emcc --pre-js, see
web/build.sh): it captures the screen and the camera and encodes them, and
decodes and shows what others share. The client carries the encoded frames
(src/client/conn/video.odin) and reaches this through Module.yapVideo
(web/shell.c). Streams are numbered as in src/common/proto/video.odin: 0 the
screen, 1 the camera.

Sharing: getDisplayMedia's track (the screen) or getUserMedia's (the
camera) is scaled to fit the size the client asks for, sampled at its
frame rate and encoded at its bitrate as H.264, HEVC or AV1 (H.264 and
HEVC as Annex B, so every keyframe carries what the decoder needs to
start). Which encoder is the client's choice, else the best that works
of those the viewers decode, as on the desktop: each is tried once on a
test frame (probeEncoders), and one that fails during a share gives way
to the next (recover). Each has a capture of its own (screen, camera)
with its own encoder. The client lowers the bitrate when
its viewers can't keep up (setBitrate), which the encoder takes up from its
next frame without a keyframe. An encoder that makes more than it's asked
for is asked for less (correctRate). Encoded frames wait in a queue until the
client pulls them. The frames come from a MediaStreamTrackProcessor where
there is one, otherwise from a <video> playing the stream, sampled from a
worker's timer - either keeps going when this tab is hidden, which it
usually is while another tab is being shared. The camera's newest frame, as
it is encoded, is also kept for the self view (takePreview); it isn't
mirrored here.

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
	// As the desktop's (KEY_SECONDS in src/video/src/share.cpp). A browser's
	// keyframes aren't held to a size, and each takes a while to go out at
	// the client's pace, holding up what follows; a viewer that needs one
	// sooner asks for it.
	const KEY_INTERVAL_MS = 10000;
	// How often what the encoder makes is compared with its bitrate, how far
	// over or under that it may be before it's asked for less or more, and
	// the least it may be asked for, as a fraction of the bitrate
	// (correctRate).
	const CORRECT_MS = 2000;
	const CORRECT_OVER = 1.1;
	const CORRECT_UNDER = 0.8;
	const CORRECT_MIN = 0.25;
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
	const H264 = 0, HEVC = 1, AV1 = 2;
	const OTHER_CODECS = { [HEVC]: "hev1.1.6.L153.B0", [AV1]: "av01.0.13M.08" };
	const CODEC_NAMES = ["H.264", "HEVC", "AV1"];

	/*
	The encoders a share may use, best first, as the desktop's
	(src/video/src/encoders.cpp): any on the GPU before the CPU's, there
	AV1, then HEVC, then H.264, and on the CPU H.264 first, which costs it
	least. The browser doesn't say whose encoder it is, only whether one on
	the GPU was asked for (prefer-hardware), which some (Firefox) take as a
	hint. `name` is what the client's settings keep (share_encoder).
	*/
	const ENCODERS = [
		{ name: "browser-av1-gpu", codec: AV1, hardware: true },
		{ name: "browser-hevc-gpu", codec: HEVC, hardware: true },
		{ name: "browser-h264-gpu", codec: H264, hardware: true },
		{ name: "browser-h264-cpu", codec: H264, hardware: false },
		{ name: "browser-av1-cpu", codec: AV1, hardware: false },
		{ name: "browser-hevc-cpu", codec: HEVC, hardware: false },
	].map((e) => ({ ...e, label: `${CODEC_NAMES[e.codec]} (on the ${e.hardware ? "GPU" : "CPU"})` }));
	// The codec strings an encoder is asked for, in order: H.264's profiles
	// (encoderConfig adds the level), the others' as for watching.
	const encoderCodecs = (e) =>
		e.codec === H264 ? H264_CODECS.map((c) => c.slice(0, 9)) : [OTHER_CODECS[e.codec]];
	// The test frame's size and rate (tryEncoder), and how long it may take.
	const PROBE_WIDTH = 1280, PROBE_HEIGHT = 720, PROBE_FPS = 30, PROBE_KBIT = 2000;
	const PROBE_TIMEOUT_MS = 5000;

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
		// The encoder the client named ("" for the best that works), what
		// the viewers decode (bits, 0 for any; setCodecs), the encoders that
		// failed during this share (recover), and how it encodes now:
		// { encoder (of ENCODERS), codec, bitrateMode } (pickEncoding). `picks`
		// is bumped by each new pick, so an older one still underway gives up.
		encoderName: "",
		codecs: 0,
		broken: new Set(),
		encoding: null,
		picks: 0,
		why: "", // why it failed, for the client; "" if the console says
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
		// What the encoder is asked for as a fraction of `bitrate`, and what
		// it made since `outSince` (correctRate).
		factor: 1,
		outBytes: 0,
		outSince: 0,
		maxWidth: 0,
		maxHeight: 0,
		audio: null, // { context, source, node } while audio is shared (the screen's)
		audioQueue: [], // Float32Arrays, interleaved stereo
		audioQueued: 0, // samples in audioQueue
		preview: null, // the camera's newest frame, not yet drawn (takePreview)
		paused: false, // nobody watches: frames are taken for the preview only (pauseCamera)
	});
	const screen = newCapture(false);
	const camera = newCapture(true);
	// By stream number.
	const captures = [screen, camera];
	const captureOf = (stream) => captures[stream] || screen;

	// start shares the screen, asking the browser's picker what.
	// `encoder` is one of ENCODERS' names, or "" for the best that works.
	function start(fps, kbit, maxWidth, maxHeight, encoder) {
		if (!canShare()) {
			screen.state = FAILED;
			return;
		}
		begin(screen, fps, kbit, maxWidth, maxHeight, encoder, () => displayMedia());
	}

	// startCamera turns on the camera `device` (a deviceId; "" for the
	// browser's choice, a phone's front camera).
	function startCamera(fps, kbit, maxWidth, maxHeight, device, encoder) {
		if (!canCamera()) {
			camera.state = FAILED;
			return;
		}
		// The settings' preview of the same camera becomes it, without asking
		// the browser again.
		begin(camera, fps, kbit, maxWidth, maxHeight, encoder, () => takeLook(device) || userMedia(device));
	}

	/* ---- the settings' camera list and preview ---- */

	// The cameras as the browser last listed them: { id, name }. Before the
	// page has been allowed a camera, browsers give neither ids nor names.
	let cameraList = [];
	function refreshCameras() {
		if (!navigator.mediaDevices || !navigator.mediaDevices.enumerateDevices) return;
		navigator.mediaDevices.enumerateDevices()
			.then((devices) => {
				cameraList = devices
					.filter((d) => d.kind === "videoinput")
					.map((d) => ({ id: d.deviceId || "", name: d.label || "" }));
			})
			.catch(() => {});
	}
	if (navigator.mediaDevices && navigator.mediaDevices.addEventListener) {
		navigator.mediaDevices.addEventListener("devicechange", refreshCameras);
	}
	refreshCameras();

	/*
	The preview the settings show while our camera is off: the camera
	`device` opened but not encoded, its frames put where the camera's own
	go (camera.preview, takePreview). Turning the camera on takes its stream
	(takeLook).
	*/
	const look = { state: OFF, device: "", stream: null, reader: null, video: null, ticker: null, generation: 0 };

	async function startLook(device, maxWidth, maxHeight) {
		if (!canCamera() || camera.state === STARTING || camera.state === LIVE) return;
		// One that failed isn't tried again (the browser would ask again) until
		// another camera is picked or the preview is let go of.
		if (look.state !== OFF && look.device === device) return;
		stopLook();
		Object.assign(look, { state: STARTING, device });
		Object.assign(camera, { maxWidth, maxHeight });
		const generation = ++look.generation;
		const current = () => generation === look.generation;
		let stream;
		try {
			stream = await userMedia(device);
		} catch (e) {
			if (current()) {
				console.warn("yap: no camera to preview:", e);
				look.state = FAILED;
			}
			return;
		}
		if (!current()) {
			stream.getTracks().forEach((t) => t.stop());
			return;
		}
		// Names come once a camera has been allowed.
		refreshCameras();
		look.stream = stream;
		const track = stream.getVideoTracks()[0];
		const keep = (frame) => {
			if (camera.state === LIVE) return;
			if (camera.preview) camera.preview.close();
			camera.preview = frame;
		};
		if (track && typeof MediaStreamTrackProcessor === "function") {
			const reader = new MediaStreamTrackProcessor({ track }).readable.getReader();
			look.reader = reader;
			(async () => {
				for (;;) {
					let result;
					try {
						result = await reader.read();
					} catch (e) {
						break;
					}
					if (result.done) break;
					if (current()) keep(result.value);
					else result.value.close();
				}
			})();
		} else if (track) {
			const video = document.createElement("video");
			video.muted = true;
			video.playsInline = true;
			video.srcObject = stream;
			video.play().catch(() => {});
			look.video = video;
			look.ticker = ticker(1000 / 30, () => {
				if (video.readyState >= 2) {
					try {
						keep(new VideoFrame(video, { timestamp: Math.round(performance.now() * 1000) }));
					} catch (e) {}
				}
			});
		}
		look.state = LIVE;
	}

	// detachLook stops reading the preview's frames; its stream is left to
	// the caller.
	function detachLook() {
		look.generation++;
		if (look.reader) look.reader.cancel().catch(() => {});
		if (look.ticker) look.ticker.stop();
		if (look.video) look.video.srcObject = null;
		const stream = look.stream;
		Object.assign(look, { state: OFF, device: "", stream: null, reader: null, video: null, ticker: null });
		return stream;
	}

	function stopLook() {
		const stream = detachLook();
		if (stream) stream.getTracks().forEach((t) => t.stop());
		if (camera.state !== LIVE && camera.preview) {
			camera.preview.close();
			camera.preview = null;
		}
	}

	// takeLook hands over the preview's stream if it is of `device`, for the
	// camera to send; null otherwise (and the preview is let go of).
	function takeLook(device) {
		if (look.state === LIVE && look.device === device && look.stream) {
			// Clones, since letting go of the preview's reader may end its
			// tracks; the camera stays open in between, without asking again.
			const taken = new MediaStream(look.stream.getVideoTracks().map((t) => t.clone()));
			const stream = detachLook();
			stream.getTracks().forEach((t) => t.stop());
			return Promise.resolve(taken);
		}
		stopLook();
		return null;
	}

	async function begin(s, fps, kbit, maxWidth, maxHeight, encoderName, open) {
		if (s.state === STARTING || s.state === LIVE) return;
		Object.assign(s, {
			fps: Math.max(1, fps),
			maxBitrate: kbit * 1000,
			bitrate: kbit * 1000,
			maxWidth,
			maxHeight,
			factor: 1,
			encoderName: encoderName || "",
			broken: new Set(),
			encoding: null,
			why: "",
		});
		s.state = STARTING;
		const generation = ++s.generation;
		const current = () => generation === s.generation;
		// While the picker is open, if they haven't been tried yet.
		probeEncoders();

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
		let encoding = null;
		if (track) {
			const { width = 1920, height = 1080 } = track.getSettings();
			encoding = await pickEncoding(s, ...fit(s, width, height));
		}
		if (!current() || !encoding) {
			stream.getTracks().forEach((t) => t.stop());
			if (current()) {
				const works = encoderList ? encoderList.filter((e) => e.works) : [];
				if (!track) {
					s.why = "the browser gave no picture";
				} else if (!works.length) {
					s.why = "this browser encodes none of H.264, HEVC and AV1";
				} else {
					s.why = "this browser can't encode it at this size";
				}
				console.warn("yap: " + s.why);
				s.state = FAILED;
			}
			return;
		}

		// A screen is text and edges more than motion, a camera the other
		// way round.
		try { track.contentHint = s.camera ? "motion" : "detail"; } catch (e) {}
		track.addEventListener("ended", () => { if (current()) stop(s, OFF); });
		console.info(`yap: ${s.camera ? "camera" : "screen"} encoded with ${describe(encoding)}`);
		s.stream = stream;
		s.encoding = encoding;
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
		console.debug(
			`yap: ${s.camera ? "camera" : "screen"} captured through ` +
			(s.reader ? "a MediaStreamTrackProcessor" : "a <video> sampled by a timer"),
		);
		const audioTrack = stream.getAudioTracks()[0];
		if (audioTrack && !s.camera) startAudio(audioTrack, current);
		s.state = LIVE;
	}

	// userMedia asks for the camera at 720p (or as big as the client asked for,
	// if bigger), so that it can be sent bigger again when the room has fewer
	// cameras (configureCamera): what is sent is scaled down from it.
	function userMedia(device) {
		const video = {
			frameRate: { ideal: 30 },
			width: { ideal: Math.max(camera.maxWidth, 1280) },
			height: { ideal: Math.max(camera.maxHeight, 720) },
		};
		if (device) video.deviceId = { exact: device };
		else video.facingMode = "user";
		return navigator.mediaDevices.getUserMedia({ video, audio: false });
	}

	// configureCamera has the camera go on at another size, frame rate or
	// bitrate. The next frame sets the encoder up again (capture), so it
	// starts with a keyframe.
	function configureCamera(fps, kbit, maxWidth, maxHeight) {
		const s = camera;
		const bitrate = kbit * 1000;
		fps = Math.max(1, fps);
		if (s.fps === fps && s.maxBitrate === bitrate && s.maxWidth === maxWidth && s.maxHeight === maxHeight) {
			return;
		}
		Object.assign(s, { fps, maxBitrate: bitrate, bitrate, maxWidth, maxHeight });
		s.width = s.height = 0;
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

	/* ---- the encoders ---- */

	// What probeEncoders found: ENCODERS, each with whether it works, those
	// that do first; null until it is done.
	let encoderList = null;
	let probing = null;

	/*
	probeEncoders tries each encoder once, on a test frame, as the desktop
	does (yv_list_encoders): a browser may say it takes a config and then
	fail on the first frame (Firefox without OpenH264). It starts with the
	first share, or when the client asks for the list (the settings), and
	the answer is kept.
	*/
	function probeEncoders() {
		if (!probing) {
			probing = (async () => {
				const list = [];
				for (const e of ENCODERS) {
					list.push({ ...e, works: canEncode() && (await tryEncoder(e)) });
				}
				const works = list.filter((e) => e.works);
				console.info("yap: encoders that work here: " + (works.map((e) => e.label).join(", ") || "none"));
				encoderList = [...works, ...list.filter((e) => !e.works)];
				return encoderList;
			})();
		}
		return probing;
	}

	// tryEncoder says whether `e` encodes a test frame with any of its codec
	// strings.
	async function tryEncoder(e) {
		const probe = { fps: PROBE_FPS, bitrate: PROBE_KBIT * 1000, factor: 1, camera: false };
		for (const codec of encoderCodecs(e)) {
			const config = encoderConfig(probe, { encoder: e, codec, bitrateMode: "variable" }, PROBE_WIDTH, PROBE_HEIGHT);
			try {
				if (!(await VideoEncoder.isConfigSupported(config)).supported) continue;
			} catch (err) {
				continue;
			}
			if (await testEncode(config)) return true;
		}
		return false;
	}

	// testEncode says whether an encoder set up as `config` makes something
	// of a grey frame within PROBE_TIMEOUT_MS.
	function testEncode(config) {
		return new Promise((resolve) => {
			let encoder = null, made = false, done = false;
			const finish = (ok) => {
				if (done) return;
				done = true;
				clearTimeout(timer);
				try { if (encoder && encoder.state !== "closed") encoder.close(); } catch (e) {}
				resolve(ok);
			};
			const timer = setTimeout(() => finish(false), PROBE_TIMEOUT_MS);
			try {
				encoder = new VideoEncoder({ output: () => { made = true; }, error: () => finish(false) });
				encoder.configure(config);
				const { width, height } = config;
				const frame = new VideoFrame(new Uint8Array((width * height * 3) / 2).fill(128), {
					format: "I420",
					codedWidth: width,
					codedHeight: height,
					timestamp: 0,
				});
				encoder.encode(frame, { keyFrame: true });
				frame.close();
				encoder.flush().then(() => finish(made), () => finish(false));
			} catch (e) {
				finish(false);
			}
		});
	}

	/*
	pickEncoding finds how to encode a capture at this size: with the
	encoder the client named, else the best that works of those its viewers
	decode (s.codecs) - or, unless `strict`, the best that works at all -
	leaving out any that failed during this share. Within an encoder, the
	first codec string it takes, at a constant bitrate if it can. A
	variable bitrate is only held to on average, if that: Firefox's goes
	from a tenth of it on a still picture to three times it on a moving
	one, and what's over the pace it goes out at waits in the client's
	queue, holding up the picture. Returns { encoder, codec, bitrateMode },
	or null if none will.
	*/
	async function pickEncoding(s, width, height, strict = false) {
		const list = await probeEncoders();
		const named = list.find((e) => e.name === s.encoderName);
		let order;
		if (named) {
			order = [named];
		} else {
			const usable = list.filter((e) => e.works && !s.broken.has(e.name));
			const decodable = usable.filter((e) => !s.codecs || s.codecs & (1 << e.codec));
			order = strict ? decodable : [...decodable, ...usable.filter((e) => !decodable.includes(e))];
		}
		for (const encoder of order) {
			for (const bitrateMode of ["constant", "variable"]) {
				for (const codec of encoderCodecs(encoder)) {
					const encoding = { encoder, codec, bitrateMode };
					try {
						const support = await VideoEncoder.isConfigSupported(encoderConfig(s, encoding, width, height));
						if (support.supported) return encoding;
					} catch (e) {}
				}
			}
		}
		return null;
	}

	const describe = (encoding) =>
		`${encoding.encoder.label}, ${encoding.codec} at a ${encoding.bitrateMode} bitrate`;

	/*
	recover goes on with the next encoder that works when the one a share
	uses fails (as one may on a frame it said it would take), from a
	keyframe. The share fails if the encoder was the client's choice, or
	if there is no other.
	*/
	async function recover(s, width, height) {
		const failed = s.encoding;
		dropEncoder(s);
		s.encoding = null;
		if (!failed) return;
		s.broken.add(failed.encoder.name);
		const generation = s.generation, pick = ++s.picks;
		const next = failed.encoder.name === s.encoderName
			? null
			: await pickEncoding(s, width || PROBE_WIDTH, height || PROBE_HEIGHT);
		if (generation !== s.generation || pick !== s.picks) return;
		if (!next) {
			s.why = `its ${failed.encoder.label} encoder failed`;
			stop(s, FAILED);
			return;
		}
		console.info(`yap: ${s.camera ? "camera" : "screen"}: going on with ${describe(next)}`);
		s.encoding = next;
		s.width = s.height = 0; // capture sets it up, from a keyframe
	}

	/*
	setCodecs says what a capture's viewers decode now (bits, 1 << codec; 0
	for any). Where that rules out what it encodes, the best encoder that
	works of those takes over, from a keyframe. One that's still fine is
	kept even if a better one would now do, since changing costs a keyframe
	and viewers come and go; so is the client's choice, whatever they
	decode (as the desktop's follow_codecs).
	*/
	async function setCodecs(s, codecs) {
		if (codecs === s.codecs) return;
		s.codecs = codecs;
		const now = s.encoding;
		if (s.state !== LIVE || !now || !codecs || codecs & (1 << now.encoder.codec)) return;
		if (now.encoder.name === s.encoderName) return;
		const generation = s.generation, pick = ++s.picks;
		const next = await pickEncoding(s, s.width || PROBE_WIDTH, s.height || PROBE_HEIGHT, true);
		if (generation !== s.generation || pick !== s.picks || s.encoding !== now) return;
		if (!next) {
			console.warn("yap: nothing else here encodes what the viewers can decode");
			return;
		}
		console.info(`yap: ${s.camera ? "camera" : "screen"}: ${describe(now)} -> ${describe(next)}, for the viewers`);
		dropEncoder(s);
		s.encoding = next;
		s.width = s.height = 0;
	}

	function dropEncoder(s) {
		if (s.encoder && s.encoder.state !== "closed") s.encoder.close();
		s.encoder = null;
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

	// encoderConfig is how a capture is encoded at this size as `encoding`
	// says (pickEncoding).
	function encoderConfig(s, encoding, width, height) {
		const { encoder, codec, bitrateMode } = encoding;
		const config = {
			codec: encoder.codec === H264 ? codec + h264Level(s, width, height) : codec,
			width,
			height,
			bitrate: Math.round(s.bitrate * s.factor),
			bitrateMode,
			framerate: s.fps,
			latencyMode: "realtime",
			hardwareAcceleration: encoder.hardware ? "prefer-hardware" : "prefer-software",
		};
		if (encoder.codec === H264) config.avc = { format: "annexb" };
		if (encoder.codec === HEVC) config.hevc = { format: "annexb" };
		return config;
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
		// None while another encoder is picked (recover).
		if (!s.encoding) return;
		const [w, h] = fit(s, width, height);
		if (w !== s.width || h !== s.height || !s.encoder) {
			// Also when a shared window changes size.
			if (!configure(s, w, h)) return;
		}
		const encoder = s.encoder;
		if (encoder.state !== "configured" || encoder.encodeQueueSize > 2) return;
		s.lastFrame = now;
		if (s.paused) {
			// Nobody watches: the self view still moves, but nothing is encoded,
			// and what follows starts from a keyframe.
			s.context.drawImage(source, 0, 0, w, h);
			if (s.preview) s.preview.close();
			s.preview = new VideoFrame(s.canvas, { timestamp: Math.round(now * 1000) });
			s.wantKey = true;
			return;
		}

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

	// configure sets the encoder up for this size at the current bitrate. A
	// new size starts with a keyframe; a new bitrate alone (key false)
	// doesn't need one, since the encoder goes on from where it was (or, if
	// it can't, starts again, which makes one anyway).
	function configure(s, width, height, key = true) {
		try {
			if (!s.encoder) {
				// What its frames are, kept with it: a new encoding gets a new
				// encoder (recover, setCodecs).
				const out = { codec: s.encoding.encoder.codec, lengthSize: 0, header: [] };
				const encoder = new VideoEncoder({
					output: (chunk, metadata) => encoded(s, out, chunk, metadata),
					error: (e) => {
						if (encoder !== s.encoder) return;
						console.warn(`yap: the encoder (${describe(s.encoding)}) failed:`, e);
						recover(s, s.width, s.height);
					},
				});
				s.encoder = encoder;
			}
			s.encoder.configure(encoderConfig(s, s.encoding, width, height));
		} catch (e) {
			console.warn("yap: can't encode " + width + "x" + height + ":", e);
			recover(s, width, height);
			return false;
		}
		s.width = s.canvas.width = width;
		s.height = s.canvas.height = height;
		s.outBytes = 0;
		s.outSince = 0;
		if (key) s.wantKey = true;
		return true;
	}

	function encoded(s, out, chunk, metadata) {
		if (metadata && metadata.decoderConfig) takeDescription(out, metadata.decoderConfig.description);
		if (s.state !== LIVE) return;
		s.outBytes += chunk.byteLength;
		const key = chunk.type === "key";
		if (s.queue.length >= MAX_QUEUED) {
			// The client isn't taking them. What's queued goes, and with it
			// anything that depends on it.
			console.debug(
				`yap: ${logTime()} ${s.camera ? "camera" : "screen"}: ` +
				`the client isn't taking frames; dropped ${s.queue.length}`,
			);
			s.queue.length = 0;
			s.awaitKey = true;
			s.wantKey = true;
		}
		if (s.awaitKey && !key) return;
		s.awaitKey = false;
		let data = new Uint8Array(chunk.byteLength);
		chunk.copyTo(data);
		data = asSent(out, data, key);
		// Stamped as it leaves the encoder, not as it was captured: viewers
		// take how late frames arrive for a network that can't keep up, and
		// an encoder that holds frames back (Firefox's H.264 keeps 8, 130 ms
		// at 60 fps) would otherwise read as one that never can, whatever
		// the bitrate.
		s.queue.push({ data, ts: Math.round(performance.now()) >>> 0, key, codec: out.codec });
		correctRate(s);
	}

	/*
	H.264 and HEVC are sent as Annex B, each keyframe starting with the
	parameter sets, and AV1 as OBUs with sizes, each keyframe with the
	sequence header. A browser that doesn't take avc or hevc { format:
	"annexb" } puts each NAL unit's length in front of it instead, and the
	parameter sets only in the description it gives with the first frame
	(avcC, hvcC); an AV1 encoder may leave the sequence header to its
	description (av1C). takeDescription keeps what's needed from it, and
	asSent puts it back.
	*/
	function takeDescription(out, description) {
		out.lengthSize = 0;
		out.header = [];
		if (!description) return;
		const d = ArrayBuffer.isView(description)
			? new Uint8Array(description.buffer, description.byteOffset, description.byteLength)
			: new Uint8Array(description);
		// Takes `n` NAL units from `i`, each with its length in two bytes in
		// front, and returns where they end.
		const units = (i, n) => {
			for (let k = 0; k < n && i + 2 <= d.length; k++) {
				const len = (d[i] << 8) | d[i + 1];
				out.header.push(d.slice(i + 2, i + 2 + len));
				i += 2 + len;
			}
			return i;
		};
		if (out.codec === H264 && d.length > 6) {
			out.lengthSize = (d[4] & 3) + 1;
			let i = units(6, d[5] & 0x1f); // SPS
			if (i < d.length) units(i + 1, d[i]); // PPS
		} else if (out.codec === HEVC && d.length > 22) {
			out.lengthSize = (d[21] & 3) + 1;
			let i = 23;
			for (let a = 0; a < d[22] && i + 3 <= d.length; a++) {
				i = units(i + 3, (d[i + 1] << 8) | d[i + 2]);
			}
		} else if (out.codec === AV1 && d.length > 4) {
			out.header.push(d.slice(4)); // configOBUs
		}
	}

	function asSent(out, data, key) {
		if (out.codec === AV1) {
			return key && out.header.length && !hasSequenceHeader(data) ? withSequenceHeader(data, out.header[0]) : data;
		}
		if (!out.lengthSize) return data;
		const START = [0, 0, 0, 1];
		const parts = [];
		if (key) for (const unit of out.header) parts.push(START, unit);
		for (let i = 0; i + out.lengthSize <= data.length;) {
			let len = 0;
			for (let k = 0; k < out.lengthSize; k++) len = len * 256 + data[i + k];
			i += out.lengthSize;
			parts.push(START, data.subarray(i, i + len));
			i += len;
		}
		const sent = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
		let at = 0;
		for (const p of parts) {
			sent.set(p, at);
			at += p.length;
		}
		return sent;
	}

	// obus lists the OBUs of an AV1 frame: { type, start, end }. It stops at
	// one without a size.
	function obus(data) {
		const list = [];
		for (let i = 0; i < data.length;) {
			const start = i, header = data[i++];
			if (!(header & 2)) break;
			if (header & 4) i++; // the extension
			let size = 0;
			for (let shift = 0; i < data.length; shift += 7) {
				const b = data[i++];
				size += (b & 0x7f) * 2 ** shift;
				if (!(b & 0x80)) break;
			}
			i += size;
			list.push({ type: (header >> 3) & 15, start, end: i });
		}
		return list;
	}

	const OBU_SEQUENCE_HEADER = 1, OBU_TEMPORAL_DELIMITER = 2;
	const hasSequenceHeader = (data) => obus(data).some((o) => o.type === OBU_SEQUENCE_HEADER);

	// withSequenceHeader puts it in front of a frame, after its temporal
	// delimiter if it has one.
	function withSequenceHeader(data, header) {
		const first = obus(data)[0];
		const at = first && first.type === OBU_TEMPORAL_DELIMITER ? first.end : 0;
		const sent = new Uint8Array(data.length + header.length);
		sent.set(data.subarray(0, at), 0);
		sent.set(header, at);
		sent.set(data.subarray(at), at + header.length);
		return sent;
	}

	/*
	correctRate asks the encoder for less than the bitrate when it makes more
	than that, and for more again when it makes less, every CORRECT_MS. An
	encoder may not keep to what it's asked for, constant or not: Firefox's
	makes twice as much at 720p, and its own keyframes on top, and what goes
	over waits in the client's queue, holding up the picture, while the
	client's cuts (setBitrate) change nothing. It moves halfway towards what
	would have been right (in proportion), so that one busy stretch doesn't
	throw it far off, and only by a tenth or more, since each change sets
	the encoder up again (configure).
	*/
	function correctRate(s) {
		const now = performance.now();
		if (!s.outSince) {
			s.outSince = now;
			s.outBytes = 0;
			return;
		}
		const ms = now - s.outSince;
		if (ms < CORRECT_MS || !s.bitrate || !s.encoder || !s.width) return;
		const made = (s.outBytes * 8 * 1000) / ms;
		s.outSince = now;
		s.outBytes = 0;
		const ratio = Math.max(made / s.bitrate, 0.01);
		if (ratio <= CORRECT_OVER && (ratio >= CORRECT_UNDER || s.factor >= 1)) return;
		const factor = Math.min(1, Math.max(CORRECT_MIN, s.factor / Math.sqrt(ratio)));
		if (Math.abs(factor - s.factor) < s.factor / 10) return;
		console.debug(
			`yap: ${logTime()} ${s.camera ? "camera" : "screen"} made ${Math.round(made / 1000)} kbit/s ` +
			`at ${Math.round(s.bitrate / 1000)}: asking for ${Math.round((s.bitrate * factor) / 1000)} ` +
			`(was ${Math.round((s.bitrate * s.factor) / 1000)})`,
		);
		s.factor = factor;
		configure(s, s.width, s.height, false);
	}

	// setBitrate has the encoder make `kbit` from its next frame, without a
	// keyframe (configure).
	function setBitrate(s, kbit) {
		const bitrate = Math.min(kbit * 1000, s.maxBitrate);
		if (s.state !== LIVE || bitrate <= 0 || bitrate === s.bitrate) return;
		s.bitrate = bitrate;
		if (s.encoder && s.width) configure(s, s.width, s.height, false);
	}

	// logTime is the time of day for the console, to match the client's log.
	function logTime() {
		const d = new Date();
		const two = (n) => String(n).padStart(2, "0");
		return `${two(d.getHours())}:${two(d.getMinutes())}:${two(d.getSeconds())}.${String(d.getMilliseconds()).padStart(3, "0")}`;
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
			stream: null, reader: null, video: null, ticker: null, encoder: null, encoding: null,
			canvas: null, context: null, width: 0, height: 0, queue: [], preview: null, paused: false,
			outBytes: 0, outSince: 0,
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
		// The encoders, best first, as { name, label, codec, hardware, works };
		// null while they are being tried (which this starts).
		encoders: () => {
			probeEncoders();
			return encoderList;
		},
		// The screen: start opens the browser's picker.
		start,
		startCamera,
		configureCamera,
		pauseCamera: (on) => { camera.paused = on; },
		// The settings' list of cameras (refreshed in the background) and
		// preview.
		refreshCameras,
		cameras: () => cameraList,
		startLook,
		stopLook,
		lookState: () => look.state,
		// The rest take the stream (0 the screen, 1 the camera).
		stop: (stream) => stop(captureOf(stream), OFF),
		state: (stream) => captureOf(stream).state,
		// Why it failed, or "" if only the console says.
		why: (stream) => captureOf(stream).why,
		setCodecs: (stream, codecs) => setCodecs(captureOf(stream), codecs),
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
