/*
Keeps the connection and the voice going when the page isn't being drawn
(emcc --pre-js, see web/build.sh).

The client steps its connection from the frame loop, and a browser stops
calling that for a hidden tab or a minimised window. A page's own timers
don't help: a hidden tab runs them at most once a second. A worker's
timers aren't held back like that, and neither are the messages it posts,
so a worker ticks every 10 ms and each tick calls web_tick, which takes
over from the frames only while they've stopped (src/client/main_web.odin).
*/
(() => {
	const TICK_MS = 10;
	const source = `setInterval(() => postMessage(0), ${TICK_MS});`;
	let worker;
	try {
		const url = URL.createObjectURL(new Blob([source], { type: "text/javascript" }));
		worker = new Worker(url);
		URL.revokeObjectURL(url);
	} catch (e) {
		// A page whose Content-Security-Policy forbids blob: workers. The
		// client still works; it just goes quiet in the background.
		console.warn("yap: no background worker, so voice stops in a hidden tab:", e);
		return;
	}
	worker.onmessage = () => {
		if (typeof Module._web_tick === "function") Module._web_tick();
	};
})();
