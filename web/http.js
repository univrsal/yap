/*
Web requests for scripts, for the web client (emcc --pre-js, see web/build.sh and
src/client/script/http_web.odin).

The client asks for a request with start() and is told of its end by
web_http_done (an export of the client's), once, with the status, the body, the
headers as "name: value" lines, and an error text if there was no answer. The
browser's rules apply: a page can only read an answer from a server that allows it
(CORS), without cookies (credentials are never sent), and an https page cannot
ask for plain http.
*/
(() => {
	const active = new Map();

	// request makes one request and resolves to { status, body: Uint8Array,
	// headers: "name: value\n..." } or { error }. The request is `req`: method, url,
	// body (Uint8Array or null), headers ("name: value\n..."), timeoutMs,
	// maxResponse (bytes), and `signal` to give up on it.
	async function request(req, signal) {
		const headers = new Headers();
		for (const line of req.headers.split("\n")) {
			const colon = line.indexOf(":");
			if (colon > 0) {
				try { headers.append(line.slice(0, colon).trim(), line.slice(colon + 1).trim()); } catch (e) { /* a name or value the browser refuses */ }
			}
		}
		let resp;
		try {
			resp = await fetch(req.url, {
				method: req.method,
				headers,
				body: req.method === "POST" ? req.body : undefined,
				redirect: "follow",
				credentials: "omit",
				cache: "no-store",
				referrerPolicy: "no-referrer",
				signal,
			});
		} catch (e) {
			if (signal.aborted) return { error: signal.reason === "timeout" ? "timed out" : "cancelled" };
			return { error: "the request failed (the server can't be reached, or doesn't allow requests from a web page)" };
		}
		const announced = Number(resp.headers.get("content-length"));
		if (announced > req.maxResponse) {
			try { await resp.body.cancel(); } catch (e) { /* nothing to cancel */ }
			return { error: "the answer is too large (more than " + (req.maxResponse >> 10) + " KiB)", status: resp.status };
		}
		const chunks = [];
		let size = 0;
		try {
			if (resp.body) {
				const reader = resp.body.getReader();
				for (;;) {
					const { done, value } = await reader.read();
					if (done) break;
					size += value.length;
					if (size > req.maxResponse) {
						await reader.cancel();
						return { error: "the answer is too large (more than " + (req.maxResponse >> 10) + " KiB)", status: resp.status };
					}
					chunks.push(value);
				}
			}
		} catch (e) {
			if (signal.aborted) return { error: signal.reason === "timeout" ? "timed out" : "cancelled" };
			return { error: "the answer could not be read" };
		}
		const body = new Uint8Array(size);
		let at = 0;
		for (const c of chunks) { body.set(c, at); at += c.length; }
		let lines = "";
		resp.headers.forEach((value, name) => { lines += name + ": " + value.replace(/[\r\n]+/g, " ") + "\n"; });
		return { status: resp.status, body, headers: lines };
	}

	function finish(id, result) {
		if (!active.delete(id) || typeof Module._web_http_done !== "function") return;
		const enc = new TextEncoder();
		const body = result.body || new Uint8Array(0);
		Module.yapWithBytes(body, (bp, bn) =>
			Module.yapWithBytes(enc.encode(result.headers || ""), (hp, hn) =>
				Module.yapWithBytes(enc.encode(result.error || ""), (ep, en) =>
					Module._web_http_done(id, result.status || 0, bp, bn, hp, hn, ep, en))));
	}

	Module.yapHttpRequest = request;
	Module.yapHttp = {
		start(id, method, url, body, headers, timeoutMs, maxResponse) {
			const ctl = new AbortController();
			active.set(id, ctl);
			const timer = setTimeout(() => ctl.abort("timeout"), timeoutMs);
			request({ method, url, body, headers, timeoutMs, maxResponse }, ctl.signal)
				.then((result) => finish(id, result))
				.finally(() => clearTimeout(timer));
		},
		abort(id) {
			const ctl = active.get(id);
			if (!ctl) return;
			active.delete(id); // nobody is told
			ctl.abort("cancelled");
		},
	};
})();
