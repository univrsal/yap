/*
The image cache, for the web client (emcc --pre-js, see web/build.sh and
src/client/conn/image_cache_web.odin): people's pictures and servers'
emoji kept in the site's IndexedDB between visits.

Two stores under the same keys (the server's key, a slash, the blob's
id): "data" has the bytes, "meta" their size and when they were last
used. Only "meta" is read when the page loads, into `index`, so how much
is kept, dropping the ones used longest ago and clearing it all are
answered without waiting; the bytes are read when the client asks for
a picture (request), and the client looks for them every turn of its
network loop (poll) until they're here (take). Until the database is
open, a picture asked for waits for it (and is fetched after all if it
isn't there), and what's stored meanwhile is written once it is. A browser that won't open it (some private windows) keeps
nothing.
*/
(() => {
	const index = new Map(); // key -> { size, used }
	const requests = new Map(); // handle -> { state, data }
	let next = 1;
	let bytes = 0;
	let max = Infinity; // until the client says (open)
	let db = null;
	let failed = typeof indexedDB === "undefined";
	let waiting = []; // what's to be done once the database is open

	function withDb(fn) {
		if (db) fn(db);
		else if (!failed) waiting.push(fn);
	}

	// Nowhere to keep anything after all: what seemed kept isn't, and
	// what's been asked for won't come.
	function giveUp(why, err) {
		console.warn(why, err);
		failed = true;
		waiting = [];
		index.clear();
		bytes = 0;
		for (const r of requests.values()) r.state = "failed";
	}

	function forget(key) {
		const entry = index.get(key);
		if (!entry) return;
		index.delete(key);
		bytes -= entry.size;
		withDb((db) => {
			const tx = db.transaction(["data", "meta"], "readwrite");
			tx.objectStore("data").delete(key);
			tx.objectStore("meta").delete(key);
		});
	}

	// Drops the pictures used longest ago until what's left fits.
	function trim() {
		while (bytes > max && index.size > 0) {
			let oldest = null;
			let oldestUsed = Infinity;
			for (const [key, entry] of index) {
				if (entry.used < oldestUsed) {
					oldest = key;
					oldestUsed = entry.used;
				}
			}
			forget(oldest);
		}
	}

	function open() {
		if (failed) return;
		let req;
		try {
			req = indexedDB.open("yap-images", 1);
		} catch (e) {
			failed = true;
			return;
		}
		req.onupgradeneeded = () => {
			req.result.createObjectStore("data");
			req.result.createObjectStore("meta");
		};
		req.onerror = () => giveUp("yap: no image cache:", req.error);
		req.onsuccess = () => {
			const opened = req.result;
			const tx = opened.transaction("meta", "readonly");
			const cursor = tx.objectStore("meta").openCursor();
			cursor.onsuccess = () => {
				const at = cursor.result;
				if (at) {
					// What was stored before this finished is newer.
					if (!index.has(at.key)) {
						index.set(at.key, { size: at.value.size, used: at.value.used });
						bytes += at.value.size;
					}
					at.continue();
					return;
				}
				db = opened;
				for (const fn of waiting) fn(db);
				waiting = [];
				trim();
			};
			cursor.onerror = () => giveUp("yap: could not read the image cache:", cursor.error);
		};
	}

	Module.yapImages = {
		// Whether there's anywhere to keep pictures.
		open(maxBytes) {
			max = maxBytes;
			trim();
			return failed ? 0 : 1;
		},

		bytes() {
			return bytes;
		},

		count() {
			return index.size;
		},

		setMax(maxBytes) {
			max = maxBytes;
			trim();
		},

		clear() {
			index.clear();
			bytes = 0;
			withDb((db) => {
				const tx = db.transaction(["data", "meta"], "readwrite");
				tx.objectStore("data").clear();
				tx.objectStore("meta").clear();
			});
		},

		// A handle to poll for the picture under `key`, or 0 if there's none.
		// Until the database is open there's no telling, so it's asked for
		// anyway, and fails then if it isn't there.
		request(key) {
			if (failed || (db && !index.has(key))) return 0;
			const handle = next++;
			const r = { state: "pending", data: null };
			requests.set(handle, r);
			withDb((db) => {
				const entry = index.get(key);
				if (!entry) {
					r.state = "failed";
					return;
				}
				const get = db.transaction("data", "readonly").objectStore("data").get(key);
				get.onsuccess = () => {
					const value = get.result;
					if (!(value instanceof Uint8Array) || value.length !== entry.size) {
						r.state = "failed";
						forget(key);
						return;
					}
					r.data = value;
					r.state = "done";
					// Used: it goes after the others.
					entry.used = Date.now();
					const meta = db.transaction("meta", "readwrite").objectStore("meta");
					meta.put({ size: entry.size, used: entry.used }, key);
				};
				get.onerror = () => {
					r.state = "failed";
				};
			});
			return handle;
		},

		// -1 while it's on its way, -2 if it won't come, else its size: then
		// take copies it out.
		poll(handle) {
			const r = requests.get(handle);
			if (!r || r.state === "failed") {
				requests.delete(handle);
				return -2;
			}
			return r.state === "pending" ? -1 : r.data.length;
		},

		take(handle, ptr, len) {
			const r = requests.get(handle);
			requests.delete(handle);
			if (r && r.data) HEAPU8.set(r.data.subarray(0, len), ptr);
		},

		cancel(handle) {
			requests.delete(handle);
		},

		store(key, ptr, len) {
			if (failed || len > max || index.has(key)) return;
			const data = HEAPU8.slice(ptr, ptr + len);
			const entry = { size: len, used: Date.now() };
			index.set(key, entry);
			bytes += len;
			withDb((db) => {
				const tx = db.transaction(["data", "meta"], "readwrite");
				tx.objectStore("data").put(data, key);
				tx.objectStore("meta").put({ size: entry.size, used: entry.used }, key);
				tx.onabort = () => {
					// Over the site's quota, most likely: not kept after all.
					console.warn("yap: could not keep a picture:", tx.error);
					if (index.get(key) === entry) {
						index.delete(key);
						bytes -= len;
					}
				};
			});
			trim();
		},
	};

	open();
})();
