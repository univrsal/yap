/*
The web client's service worker (docs/design/mobile.md, web/push.js): it shows
what a server pushes while the client isn't open, and takes a tap on
one to the conversation it's about.

It's registered once for each server that pushes, under push/<id>/
(<id> the server's address in hex), and once under push/page/ for the
page's own notifications where the page can't show them itself. It
controls no page: it only shows notifications.

A push is JSON from the server (src/server/push_notify.odin):
{kind, server, conv, msg, title, body, tag, quiet, ring}. Each conversation
has one notification (its tag), counting the messages it stands for; a
call has one of its own, which stays up while it rings and is replaced
by what came of it. A browser wants every push to show a notification
(Safari and Firefox take the subscription away from a site whose pushes
don't), so every one does.
*/

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

// The server this registration is for (its scope's last part), and the
// client's page, two up from there.
function serverId() {
	const parts = new URL(self.registration.scope).pathname.split("/").filter(Boolean);
	return parts[parts.length - 1] || "";
}
function appUrl() {
	return new URL("../../", self.registration.scope).href;
}

/*
The number on the app's icon: unread DMs and mentions, as the page last
counted them (web/push.js keeps it in the Cache storage), and one more
for each pushed since. The page puts it right when it's next opened.
*/
async function badgeAdd() {
	if (!("setAppBadge" in self.navigator)) return;
	try {
		const key = new URL("push/badge", appUrl()).href;
		const cache = await caches.open("yap-badge");
		const old = await cache.match(key);
		const n = (old ? parseInt(await old.text(), 10) || 0 : 0) + 1;
		await cache.put(key, new Response(String(n)));
		await self.navigator.setAppBadge(n);
	} catch (err) {}
}

self.addEventListener("push", (event) => {
	let p = {};
	try {
		p = event.data ? event.data.json() : {};
	} catch (err) {}
	const tag = p.tag || "c" + (p.conv || 0);
	const call = p.kind === "call";
	event.waitUntil(
		(async () => {
			let count = 1;
			if (!call) {
				for (const old of await self.registration.getNotifications({ tag })) {
					count += (old.data && old.data.count) || 1;
				}
			}
			let body = p.body || "";
			if (count > 1) body = (body ? body + "\n" : "") + "(" + count + " new messages)";
			await self.registration.showNotification(p.title || "yap", {
				body,
				tag,
				renotify: !p.quiet,
				silent: !!p.quiet,
				requireInteraction: !!p.ring,
				icon: new URL("icon-192.png", appUrl()).href,
				data: { id: serverId(), conv: p.conv || 0, msg: p.msg || 0, count },
			});
			if (p.kind === "dm" || p.kind === "group" || p.kind === "mention") await badgeAdd();
		})(),
	);
});

self.addEventListener("notificationclick", (event) => {
	event.notification.close();
	const d = event.notification.data || {};
	const app = appUrl();
	event.waitUntil(
		(async () => {
			// A call's has no message: the page is enough, where it rings.
			const open = d.conv && d.msg ? { id: d.id, conv: d.conv, msg: d.msg } : null;
			const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
			for (const w of windows) {
				if (!w.url.startsWith(app)) continue;
				await w.focus();
				if (open) w.postMessage({ yapOpen: open });
				return;
			}
			await self.clients.openWindow(open ? app + "#open=" + open.id + "/" + open.conv + "/" + open.msg : app);
		})(),
	);
});
