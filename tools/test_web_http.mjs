// Tests web/http.js (the browser side of scripts' web requests) in node, which has
// fetch: the request code itself, and what it hands to the client's web_http_done.
//
//	node tools/test_web_http.mjs
import http from "node:http";
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");

// What emscripten provides to a --pre-js: Module, and a heap.
const heap = new Uint8Array(1 << 22);
let top = 16;
const calls = [];
const context = {
	Module: {
		_web_http_done(...args) {
			// Read the strings out of the heap, as the client does.
			const [id, status, bp, bn, hp, hn, ep, en] = args;
			const text = (p, n) => new TextDecoder().decode(heap.slice(p, p + n));
			calls.push({ id, status, body: text(bp, bn), headers: text(hp, hn), error: text(ep, en) });
		},
	},
	_malloc: (n) => { const p = top; top += n + 8; if (top > heap.length) top = 16; return p; },
	_free: () => {},
	HEAPU8: heap,
	fetch, Headers, AbortController, TextEncoder, TextDecoder, Uint8Array, setTimeout, clearTimeout, URL,
};
vm.createContext(context);
for (const file of ["util.js", "http.js"]) {
	vm.runInContext(fs.readFileSync(path.join(root, "web", file), "utf8"), context, { filename: file });
}
const request = context.Module.yapHttpRequest;

const server = http.createServer((req, res) => {
	const chunks = [];
	req.on("data", (c) => chunks.push(c));
	req.on("end", () => {
		const body = Buffer.concat(chunks).toString();
		switch (req.url) {
		case "/small":
			res.writeHead(200, { "Content-Type": "text/plain", "X-Test": "yes", "Set-Cookie": "a=b" });
			res.end("hello from the server");
			break;
		case "/missing":
			res.writeHead(404);
			res.end("nothing here");
			break;
		case "/big":
			res.writeHead(200);
			res.end(Buffer.alloc(3 * 1024 * 1024, "x"));
			break;
		case "/big-chunked":
			res.writeHead(200); // no content-length: it has to be counted
			for (let i = 0; i < 30; i++) res.write(Buffer.alloc(100 * 1024, "y"));
			res.end();
			break;
		case "/hop":
			res.writeHead(302, { Location: "/small" });
			res.end();
			break;
		case "/slow":
			setTimeout(() => { res.writeHead(200); res.end("late"); }, 3000);
			break;
		case "/echo":
			res.writeHead(200);
			res.end(JSON.stringify({ method: req.method, type: req.headers["content-type"], token: req.headers["x-token"], cookie: req.headers["cookie"] || null, referer: req.headers["referer"] || null, body }));
			break;
		default:
			res.writeHead(404);
			res.end("?");
		}
	});
});
await new Promise((ok) => server.listen(0, "127.0.0.1", ok));
const base = `http://127.0.0.1:${server.address().port}`;
const plain = { method: "GET", body: null, headers: "", maxResponse: 1 << 20 };
const run = (req, ms = 5000) => {
	const ctl = new AbortController();
	const timer = setTimeout(() => ctl.abort("timeout"), ms);
	return request({ ...plain, ...req }, ctl.signal).finally(() => clearTimeout(timer));
};

let failed = 0;
async function test(name, fn) {
	try { await fn(); console.log("ok   ", name); } catch (e) { failed++; console.log("FAIL ", name, "\n", e.message); }
}
const text = (r) => new TextDecoder().decode(r.body);

await test("a plain answer, with its headers", async () => {
	const r = await run({ url: base + "/small" });
	assert.equal(r.status, 200);
	assert.equal(text(r), "hello from the server");
	assert.match(r.headers, /content-type: text\/plain\n/);
	assert.match(r.headers, /x-test: yes\n/);
});
await test("a 404 is an answer", async () => {
	const r = await run({ url: base + "/missing" });
	assert.equal(r.status, 404);
	assert.equal(text(r), "nothing here");
	assert.equal(r.error, undefined);
});
await test("a redirect is followed", async () => {
	const r = await run({ url: base + "/hop" });
	assert.equal(r.status, 200);
	assert.equal(text(r), "hello from the server");
});
await test("POST with a body and headers; no cookies, no referrer", async () => {
	const r = await run({ method: "POST", url: base + "/echo", body: new TextEncoder().encode('{"a":1}'), headers: "Content-Type: application/json\nX-Token: abc\nBad Header Name: x\n" });
	const echoed = JSON.parse(text(r));
	assert.deepEqual(echoed, { method: "POST", type: "application/json", token: "abc", cookie: null, referer: null, body: '{"a":1}' });
});
await test("an answer that announces it is too large", async () => {
	const r = await run({ url: base + "/big" });
	assert.match(r.error, /too large/);
	assert.equal(r.body, undefined);
});
await test("an answer that turns out too large while it is read", async () => {
	const r = await run({ url: base + "/big-chunked" });
	assert.match(r.error, /too large/);
});
await test("a timeout", async () => {
	const began = Date.now();
	const r = await run({ url: base + "/slow" }, 300);
	assert.equal(r.error, "timed out");
	assert.ok(Date.now() - began < 2000);
});
await test("a server that isn't there", async () => {
	const r = await run({ url: "http://127.0.0.1:1/" });
	assert.match(r.error, /request failed/);
});
await test("the glue hands the answer to web_http_done, once, with the strings intact", async () => {
	calls.length = 0;
	context.Module.yapHttp.start(7, "GET", base + "/small", new Uint8Array(0), "", 5000, 1 << 20);
	context.Module.yapHttp.start(8, "GET", base + "/missing", new Uint8Array(0), "", 5000, 1 << 20);
	for (let i = 0; i < 100 && calls.length < 2; i++) await new Promise((ok) => setTimeout(ok, 20));
	assert.equal(calls.length, 2);
	const by = Object.fromEntries(calls.map((c) => [c.id, c]));
	assert.equal(by[7].status, 200);
	assert.equal(by[7].body, "hello from the server");
	assert.match(by[7].headers, /x-test: yes/);
	assert.equal(by[7].error, "");
	assert.equal(by[8].status, 404);
});
await test("aborting a request tells nobody", async () => {
	calls.length = 0;
	context.Module.yapHttp.start(9, "GET", base + "/slow", new Uint8Array(0), "", 5000, 1 << 20);
	context.Module.yapHttp.abort(9);
	await new Promise((ok) => setTimeout(ok, 300));
	assert.equal(calls.length, 0);
});

server.closeAllConnections();
server.close();
process.exit(failed ? 1 : 0);
