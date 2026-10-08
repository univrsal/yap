/*
Files in DMs, for the web client (emcc --pre-js, see web/build.sh and
src/client/files_io_web.odin).

Picking: a file input the page clicks for the client, for one file or
(to attach to a message) several; each File is kept here under a handle
and only its name and size go to the client (web_file_picked, once for
each). Reading it: the client asks for bytes at an offset
(read), which come out of 1 MB blocks read ahead with File.slice. A
block that isn't here yet starts loading and the client is told to come
back (-1).

Receiving: chunks are copied into 1 MB blocks, and a full block becomes
a Blob, which a browser can keep on disk rather than in memory. When
the file is complete the blocks make one Blob, offered as a download
under the sender's name.
*/
(() => {
	const BLOCK = 1 << 20;
	const KEEP = 8; // blocks of a picked file kept at once
	const files = new Map();
	const sinks = new Map();
	let next = 1;

	function load(entry, index) {
		const start = index * BLOCK;
		const end = Math.min(start + BLOCK, entry.file.size);
		entry.blocks.set(index, "loading");
		entry.order.push(index);
		while (entry.order.length > KEEP) entry.blocks.delete(entry.order.shift());
		entry.file.slice(start, end).arrayBuffer().then(
			(buf) => { if (entry.blocks.has(index)) entry.blocks.set(index, new Uint8Array(buf)); },
			(err) => { console.error("yap: could not read the file", err); entry.failed = true; },
		);
	}

	// A File the client is to know of: kept under a handle, and its name
	// and size told to `notify` (an export of the client's).
	function tell(file, notify) {
		const handle = next++;
		files.set(handle, { file, blocks: new Map(), order: [], failed: false });
		const name = new TextEncoder().encode(file.name);
		const ptr = _malloc(name.length + 1);
		HEAPU8.set(name, ptr);
		notify(handle, ptr, name.length, file.size);
		_free(ptr);
	}

	// Files dropped on the page are attached to the message being written
	// (web_file_dropped). Without this the browser would open them.
	window.addEventListener("dragover", (e) => {
		if (e.dataTransfer && Array.from(e.dataTransfer.types).includes("Files")) {
			e.preventDefault();
			e.dataTransfer.dropEffect = "copy";
		}
	});
	window.addEventListener("drop", (e) => {
		if (!e.dataTransfer || !e.dataTransfer.files.length) return;
		e.preventDefault();
		if (typeof Module._web_file_dropped !== "function") return;
		for (const file of e.dataTransfer.files) {
			// A folder comes as a File of no type and no size; it can't be read.
			if (file.size === 0 && file.type === "") continue;
			tell(file, Module._web_file_dropped);
		}
	});

	Module.yapFiles = {
		pick(accept, multiple) {
			const input = document.createElement("input");
			input.type = "file";
			input.accept = accept;
			input.multiple = !!multiple;
			input.addEventListener("change", () => {
				if (!input.files || typeof Module._web_file_picked !== "function") return;
				for (const file of input.files) {
					tell(file, Module._web_file_picked);
				}
			});
			input.click();
		},

		// Copies `len` bytes from `offset` to `ptr`: len once they're here,
		// -1 while they're loading, -2 if they can't be read.
		read(handle, offset, ptr, len) {
			const entry = files.get(handle);
			if (!entry || entry.failed) return -2;
			let done = 0;
			while (done < len) {
				const pos = offset + done;
				const index = Math.floor(pos / BLOCK);
				const block = entry.blocks.get(index);
				if (!(block instanceof Uint8Array)) {
					if (block === undefined) load(entry, index);
					return -1;
				}
				const from = pos - index * BLOCK;
				const n = Math.min(len - done, block.length - from);
				if (n <= 0) return -2;
				HEAPU8.set(block.subarray(from, from + n), ptr + done);
				done += n;
			}
			// Read ahead, so the next chunks are here when they're wanted.
			const ahead = Math.floor((offset + len) / BLOCK) + 1;
			if (ahead * BLOCK < entry.file.size && !entry.blocks.has(ahead)) load(entry, ahead);
			return len;
		},

		// A File made here rather than picked (a pasted picture, web/paste.js),
		// kept and told of like a picked one.
		tell,

		close(handle) {
			files.delete(handle);
		},

		sinkOpen(name, size) {
			const handle = next++;
			sinks.set(handle, { name, size, blocks: new Map() });
			return handle;
		},

		sinkWrite(handle, offset, ptr, len) {
			const sink = sinks.get(handle);
			if (!sink) return 0;
			let done = 0;
			while (done < len) {
				const pos = offset + done;
				const index = Math.floor(pos / BLOCK);
				const size = Math.min(BLOCK, sink.size - index * BLOCK);
				let block = sink.blocks.get(index);
				if (block instanceof Blob) return 0; // already complete: can't be
				if (!block) {
					block = { buf: new Uint8Array(size), filled: 0 };
					sink.blocks.set(index, block);
				}
				const from = pos - index * BLOCK;
				const n = Math.min(len - done, size - from);
				block.buf.set(HEAPU8.subarray(ptr + done, ptr + done + n), from);
				block.filled += n;
				done += n;
				if (block.filled >= size) sink.blocks.set(index, new Blob([block.buf]));
			}
			return 1;
		},

		sinkFinish(handle) {
			const sink = sinks.get(handle);
			if (!sink) return 0;
			sinks.delete(handle);
			const count = Math.ceil(sink.size / BLOCK);
			const parts = [];
			for (let i = 0; i < count; i++) {
				const block = sink.blocks.get(i);
				if (!(block instanceof Blob)) return 0;
				parts.push(block);
			}
			const url = URL.createObjectURL(new Blob(parts, { type: "application/octet-stream" }));
			const link = document.createElement("a");
			link.href = url;
			link.download = sink.name;
			document.body.appendChild(link);
			link.click();
			link.remove();
			setTimeout(() => URL.revokeObjectURL(url), 60000);
			return 1;
		},

		sinkAbort(handle) {
			sinks.delete(handle);
		},
	};
})();
