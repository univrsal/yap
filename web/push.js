/*
Web Push for the web client (emcc --pre-js, see web/build.sh,
src/client/ui_push_web.odin and misc/mobile): subscribing this browser
to a server's pushes, and what comes back from the notifications they
show (web/sw.js).

A browser keeps one push subscription for each service-worker
registration, tied to one server's key, and the client may be logged in
to several servers. So sw.js is registered once per server, each under
a scope of its own, push/<id>/ (the id is the server's address in hex);
each registration has its own subscription, and the worker is the same.

Everything here is a promise, and the client is a frame loop: it asks
(check, enable, disable) and then looks every frame at how it's going
(state) and at what to tell the server (take, takeUnsubscribe).

States, as the client reads them:
  0 the browser can't (no service workers or Push API, or not HTTPS)
  1 off            2 working on it         3 on
  4 blocked: the user said no, and only the browser's settings undo it
  5 failed: see the console
  6 on an iPhone or iPad in a Safari tab: only the home screen's app can
*/
(() => {
	const ios =
		/iPad|iPhone|iPod/.test(navigator.userAgent) ||
		(navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
	const standalone =
		navigator.standalone === true ||
		(typeof matchMedia === "function" && matchMedia("(display-mode: standalone)").matches);
	const supported =
		typeof window !== "undefined" &&
		window.isSecureContext &&
		"serviceWorker" in navigator &&
		typeof PushManager !== "undefined" &&
		typeof Notification !== "undefined";

	const servers = new Map(); // id -> { state, sub, unsubscribe }
	const opens = []; // what tapping a notification asked to be shown

	function idOf(server) {
		let hex = "";
		for (const b of new TextEncoder().encode(server)) hex += b.toString(16).padStart(2, "0");
		return hex;
	}
	function serverOf(id) {
		const bytes = new Uint8Array(id.length / 2);
		for (let i = 0; i < bytes.length; i++) bytes[i] = parseInt(id.substr(i * 2, 2), 16);
		return new TextDecoder().decode(bytes);
	}
	function scopeOf(id) {
		return new URL("push/" + id + "/", document.baseURI).href;
	}
	function entry(id) {
		let e = servers.get(id);
		if (!e) {
			e = { state: supported ? 1 : ios && !standalone ? 6 : 0, sub: null, unsubscribe: false };
			servers.set(id, e);
		}
		return e;
	}
	function fromBase64url(s) {
		const b = atob(s.replace(/-/g, "+").replace(/_/g, "/"));
		return Uint8Array.from(b, (c) => c.charCodeAt(0));
	}
	function keysOf(sub) {
		const j = sub.toJSON();
		return { endpoint: j.endpoint, p256dh: fromBase64url(j.keys.p256dh), auth: fromBase64url(j.keys.auth) };
	}
	function sameKey(sub, key) {
		const k = sub.options && sub.options.applicationServerKey;
		if (!k) return true; // a browser that doesn't say
		const a = new Uint8Array(k);
		return a.length === key.length && a.every((b, i) => b === key[i]);
	}
	function blockedOr(state) {
		return Notification.permission === "denied" ? 4 : state;
	}
	// A registration's worker, once it's active: subscribing needs one.
	function active(reg) {
		if (reg.active) return Promise.resolve(reg);
		const w = reg.installing || reg.waiting;
		return new Promise((resolve, reject) => {
			w.addEventListener("statechange", () => {
				if (w.state === "activated") resolve(reg);
				else if (w.state === "redundant") reject(new Error("the service worker failed to install"));
			});
		});
	}
	function registration(id) {
		return navigator.serviceWorker.getRegistration(scopeOf(id)).then((reg) =>
			// getRegistration gives the closest one that covers the URL,
			// which may be another's: only its own counts.
			reg && reg.scope === scopeOf(id) ? reg : null,
		);
	}

	async function check(id, key) {
		const e = entry(id);
		if (!supported || e.state === 2) return;
		e.state = 2;
		try {
			const reg = await registration(id);
			const sub = reg && (await reg.pushManager.getSubscription());
			if (!sub) {
				e.state = blockedOr(1);
				return;
			}
			if (!sameKey(sub, key)) {
				// The server has a new key: the old subscription is no use.
				await sub.unsubscribe();
				e.state = 1;
				if (Notification.permission === "granted") await enable(id, key);
				return;
			}
			// Given again: the server may have forgotten it, or the
			// browser changed the endpoint.
			e.sub = keysOf(sub);
			e.state = 3;
		} catch (err) {
			console.warn("yap: couldn't look at push notifications:", err);
			e.state = 5;
		}
	}

	async function enable(id, key) {
		const e = entry(id);
		if (!supported) return;
		e.state = 2;
		try {
			// First, while the tap that asked for it still counts: the
			// browser only asks the user then.
			const permission =
				Notification.permission === "granted" ? "granted" : await Notification.requestPermission();
			if (permission !== "granted") {
				e.state = blockedOr(1);
				return;
			}
			const reg = await active(
				await navigator.serviceWorker.register(new URL("sw.js", document.baseURI).href, {
					scope: scopeOf(id),
				}),
			);
			const sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key });
			e.sub = keysOf(sub);
			e.state = 3;
		} catch (err) {
			console.warn("yap: couldn't turn push notifications on:", err);
			e.state = blockedOr(5);
		}
	}

	async function disable(id) {
		const e = entry(id);
		if (!supported) return;
		e.state = 2;
		e.sub = null;
		e.unsubscribe = true; // the server is told at once
		try {
			const reg = await registration(id);
			if (reg) {
				const sub = await reg.pushManager.getSubscription();
				if (sub) await sub.unsubscribe();
				await reg.unregister();
			}
			e.state = blockedOr(1);
		} catch (err) {
			console.warn("yap: couldn't turn push notifications off:", err);
			e.state = 5;
		}
	}

	// A conversation is being read here: its notification can go.
	async function seen(id, conv) {
		if (!supported) return;
		try {
			const reg = await registration(id);
			if (!reg) return;
			for (const n of await reg.getNotifications({ tag: "c" + conv })) n.close();
		} catch (err) {}
	}

	// Tapped while the page was open (web/sw.js tells it), or the page
	// opened by tapping one: #open=<id>/<conv>/<msg>.
	function opened(id, conv, msg) {
		if (/^([0-9a-f]{2})+$/.test(id)) opens.push({ server: serverOf(id), conv: conv >>> 0, msg: +msg || 0 });
	}
	if (supported) {
		navigator.serviceWorker.addEventListener("message", (event) => {
			const o = event.data && event.data.yapOpen;
			if (o) opened(String(o.id), o.conv, o.msg);
		});
	}
	const hash = /^#open=([0-9a-f]+)\/(\d+)\/(\d+)$/.exec(location.hash);
	if (hash) {
		opened(hash[1], +hash[2], +hash[3]);
		history.replaceState(null, "", location.pathname + location.search);
	}

	/*
	A notification from the page itself (web/shell.c's yap_notify), where
	`new Notification` isn't allowed: Chrome on Android wants them shown
	by a service worker. One under push/page/, whatever servers push.
	*/
	let pageReg = null;
	function notify(title, body) {
		if (!supported) return;
		if (!pageReg) {
			pageReg = navigator.serviceWorker
				.register(new URL("sw.js", document.baseURI).href, {
					scope: new URL("push/page/", document.baseURI).href,
				})
				.then(active);
		}
		pageReg
			.then((reg) => reg.showNotification(title, body ? { body, tag: "page" } : { tag: "page" }))
			.catch((err) => console.warn("yap: couldn't show a notification:", err));
	}

	/*
	The number on the app's icon (the Badging API: an installed app on
	iOS 16.4+, macOS, Windows; not Android): unread DMs and mentions. The
	page sets it as the client counts it; while it's closed, sw.js adds
	one for each DM or mention pushed. Both keep it in the Cache storage
	under push/badge, so the worker counts on from the page's number.
	*/
	let badgeShown = -1;
	function badge(n) {
		if (n === badgeShown) return;
		badgeShown = n;
		try {
			if ("setAppBadge" in navigator) {
				(n > 0 ? navigator.setAppBadge(n) : navigator.clearAppBadge()).catch(() => {});
			}
			if (typeof caches !== "undefined") {
				caches
					.open("yap-badge")
					.then((c) => c.put(new URL("push/badge", document.baseURI).href, new Response(String(n))))
					.catch(() => {});
			}
		} catch (err) {}
	}

	Module.yapPush = {
		badge,
		state: (server) => entry(idOf(server)).state,
		check: (server, key) => check(idOf(server), key),
		enable: (server, key) => enable(idOf(server), key),
		disable: (server) => disable(idOf(server)),
		// The subscription to give the server, once.
		take: (server) => {
			const e = entry(idOf(server));
			const sub = e.sub;
			e.sub = null;
			return sub;
		},
		takeUnsubscribe: (server) => {
			const e = entry(idOf(server));
			const was = e.unsubscribe;
			e.unsubscribe = false;
			return was;
		},
		seen: (server, conv) => seen(idOf(server), conv),
		takeOpen: () => opens.shift() || null,
		notify,
	};
})();
