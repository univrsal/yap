// An echo bot in Node, with nothing but what Node has (22 or later:
// fetch and WebSocket): answers "!echo <text>" with <text>.
//
//     YAP_URL=http://localhost:8080 YAP_TOKEN=yap_... node echo.mjs

const api = (process.env.YAP_URL ?? "http://localhost:8080").replace(/\/$/, "") + "/api/v1";
const token = process.env.YAP_TOKEN;
const headers = { Authorization: `Bot ${token}`, "Content-Type": "application/json" };

async function post(convId, content, thread) {
	for (;;) {
		const r = await fetch(`${api}/convs/${convId}/messages`, {
			method: "POST",
			headers,
			body: JSON.stringify({ content, thread }),
		});
		if (r.status !== 429) {
			if (!r.ok) throw new Error(`${r.status}: ${(await r.json()).message}`);
			return r.json();
		}
		const wait = Number(r.headers.get("Retry-After") ?? 1);
		await new Promise((done) => setTimeout(done, wait * 1000));
	}
}

let me = null;
let last = null; // the last event's number, to resume from

function connect() {
	// A browser's WebSocket can't set headers: the token in the URL works
	// with any.
	let url = api.replace(/^http/, "ws") + `/events?token=${token}`;
	if (last !== null) url += `&resume=${last}`;
	const ws = new WebSocket(url);
	ws.onmessage = async (frame) => {
		const { t, s, d } = JSON.parse(frame.data);
		last = s;
		if (t === "READY") {
			me = d.me.id;
			console.log(`ready as ${d.me.username}, in ${d.convs.length} conversations`);
		} else if (t === "MESSAGE_CREATE" && d.author.id !== me && d.content.startsWith("!echo ")) {
			await post(d.conv_id, d.content.slice("!echo ".length), d.thread);
		}
	};
	ws.onclose = (e) => {
		if (e.code === 4000 || e.code === 4001) {
			// Another copy took over, or the token stopped working.
			console.log(`closed (${e.code}): ${e.reason}`);
			return;
		}
		setTimeout(connect, 2000);
	};
}

connect();
