/*
Sound files of the user's own, for the web client (emcc --pre-js, see
web/build.sh and src/client/ui_sounds_web.odin). The browser decodes any
format it knows (decodeAudioData), at 48 kHz in stereo, which is what the
client mixes; the client is handed the samples. The file itself is kept
in IndexedDB ("yap-sounds"), under the name the client keeps in its
settings ("custom:<name>" there), and decoded again at the next start
(load).

pick(kind): a file input for an event's sound. A file that is too big or
doesn't decode is reported (web_sound_failed); otherwise it is stored
under a name of its own (its file name, or with "-2" and so on if another
file of that name is stored; the same file again is the same one) and
handed over (web_sound_picked).

load(name): the stored file of that name, decoded (web_sound_loaded), or
that it can't be (web_sound_missing).

remove(name): forgets a file no event plays any more.
*/
(() => {
	// Keep these in step with audio.SOUND_FILE_MAX, SOUND_MAX_SECONDS and
	// SOUND_FILE_NAME_MAX.
	const MAX_BYTES = 5 * 1024 * 1024;
	const MAX_SECONDS = 30;
	const MAX_NAME = 64;
	const RATE = 48000;

	let dbPromise = null;
	const db = () => {
		if (!dbPromise) {
			dbPromise = new Promise((resolve, reject) => {
				if (typeof indexedDB === "undefined") {
					reject(new Error("no IndexedDB"));
					return;
				}
				const req = indexedDB.open("yap-sounds", 1);
				req.onupgradeneeded = () => req.result.createObjectStore("files");
				req.onsuccess = () => resolve(req.result);
				req.onerror = () => reject(req.error);
			});
		}
		return dbPromise;
	};
	const request = (mode, fn) =>
		db().then(
			(d) =>
				new Promise((resolve, reject) => {
					const req = fn(d.transaction("files", mode).objectStore("files"));
					req.onsuccess = () => resolve(req.result);
					req.onerror = () => reject(req.error);
				}),
		);
	const get = (name) => request("readonly", (s) => s.get(name));
	const put = (name, bytes) => request("readwrite", (s) => s.put(bytes, name));

	const decode = async (bytes) => {
		const Ctx = window.OfflineAudioContext || window.webkitOfflineAudioContext;
		const ctx = new Ctx(2, 1, RATE);
		// decodeAudioData detaches the buffer it is given.
		const buffer = await ctx.decodeAudioData(bytes.slice().buffer);
		const frames = Math.min(buffer.length, MAX_SECONDS * RATE);
		const left = buffer.getChannelData(0);
		const right = buffer.numberOfChannels > 1 ? buffer.getChannelData(1) : left;
		const out = new Float32Array(frames * 2);
		for (let i = 0; i < frames; i++) {
			out[2 * i] = left[i];
			out[2 * i + 1] = right[i];
		}
		return out;
	};

	// The name cut to MAX_NAME bytes of UTF-8, keeping its extension.
	const fit = (name) => {
		const enc = new TextEncoder();
		if (enc.encode(name).length <= MAX_NAME) return name;
		const dot = name.lastIndexOf(".");
		const ext = dot > 0 && name.length - dot <= 8 ? name.slice(dot) : "";
		let stem = name.slice(0, name.length - ext.length);
		while (stem && enc.encode(stem + ext).length > MAX_NAME) {
			stem = Array.from(stem).slice(0, -1).join("");
		}
		return stem + ext;
	};

	const same = (a, b) => {
		if (!a || a.length !== b.length) return false;
		for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
		return true;
	};

	// Stores the file under a name of its own, and returns that name.
	const store = async (fileName, bytes) => {
		const clean = fit(fileName.replace(/[\/\\\x00-\x1f]/g, "_").replace(/^\.+/, "") || "sound");
		const dot = clean.lastIndexOf(".");
		const stem = dot > 0 ? clean.slice(0, dot) : clean;
		const ext = dot > 0 ? clean.slice(dot) : "";
		for (let n = 1; n <= 100; n++) {
			const name = n === 1 ? clean : fit(`${stem}-${n}${ext}`);
			const old = await get(name);
			if (old === undefined) {
				await put(name, bytes);
				return name;
			}
			if (same(old, bytes)) return name;
		}
		throw new Error("no name left");
	};

	const withString = (s, fn) => {
		const bytes = new TextEncoder().encode(s);
		const ptr = _malloc(bytes.length + 1);
		HEAPU8.set(bytes, ptr);
		try {
			fn(ptr, bytes.length);
		} finally {
			_free(ptr);
		}
	};
	const withSamples = (samples, fn) => {
		const ptr = _malloc(samples.length * 4);
		HEAPU8.set(new Uint8Array(samples.buffer), ptr);
		try {
			fn(ptr, samples.length / 2);
		} finally {
			_free(ptr);
		}
	};

	Module.yapSounds = {
		pick(kind) {
			const input = document.createElement("input");
			input.type = "file";
			input.accept = "audio/*,.opus,.ogg,.wav,.flac,.mp3,.m4a";
			input.addEventListener("change", async () => {
				const file = input.files && input.files[0];
				if (!file || typeof Module._web_sound_picked !== "function") return;
				const fail = (why) => withString(why, (p, n) => Module._web_sound_failed(kind, p, n));
				if (file.size > MAX_BYTES) {
					fail(`That file is too big: a sound can be at most ${MAX_BYTES / (1024 * 1024)} MB.`);
					return;
				}
				let bytes, samples;
				try {
					bytes = new Uint8Array(await file.arrayBuffer());
					samples = await decode(bytes);
				} catch (e) {
					fail("That file can't be played (the browser can't decode it).");
					return;
				}
				if (samples.length === 0) {
					fail("That file can't be played (no sound in it).");
					return;
				}
				let name;
				try {
					name = await store(file.name, bytes);
				} catch (e) {
					console.error("yap: could not keep the sound", e);
					fail("That file couldn't be kept in the browser's storage.");
					return;
				}
				withString(name, (np, nl) =>
					withSamples(samples, (sp, frames) => Module._web_sound_picked(kind, np, nl, sp, frames)),
				);
			});
			input.click();
		},

		async load(name) {
			let samples = null;
			let why = "";
			try {
				const bytes = await get(name);
				if (bytes === undefined) why = "is gone";
				else samples = await decode(bytes);
			} catch (e) {
				why = "can't be played";
			}
			if (samples && samples.length > 0) {
				withString(name, (np, nl) =>
					withSamples(samples, (sp, frames) => Module._web_sound_loaded(np, nl, sp, frames)),
				);
			} else {
				withString(name, (np, nl) =>
					withString(why || "can't be played", (wp, wl) => Module._web_sound_missing(np, nl, wp, wl)),
				);
			}
		},

		remove(name) {
			request("readwrite", (s) => s.delete(name)).catch((e) =>
				console.error("yap: could not forget a sound", e),
			);
		},
	};
})();
