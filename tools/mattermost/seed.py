#!/usr/bin/env python3
"""
Fills a fresh Mattermost with one of everything a yap import has to deal
with, through its REST API and mmctl, so that its export can be the
importer's test data (docs/design/mattermost-import.md, step 6).

	tools/mattermost/seed.py <base url> <container> <password>

<container> runs Mattermost with local mode on (docker-compose.yml here
sets it up); <password> is given to every account it makes. Run it once,
on an empty instance: it doesn't check what is there already.

What it makes:

  - accounts: admin (system admin), alice (team admin, first and last
    name), bob (nickname), carol, dave (deactivated at the end), erin
    (only in the second team), frank (an uploaded profile picture), gus
    (a guest, if the edition allows it), and a bot, buildbot.
  - teams: acme, and other with a channel of its own.
  - channels: town-square, off-topic, general-talk (bob is its channel
    admin), secret (private), old-stuff (archived), phoenix (archived
    and restored), and every kind of channel change in general-talk.
  - posts: mentions (people, @here, @channel, @all, a deactivated user,
    someone in the other team), channel links, emoji, Markdown, a long
    one, threads, a deleted root with replies, a deleted reply, edits,
    pins, saved posts, reactions (custom emoji too), files and a
    picture, /me, a bot's post with and without an overridden name, and
    an incoming webhook's post with a message attachment.
  - DMs: alice-bob, alice with herself, alice-dave (dave is deactivated
    afterwards), alice-erin (erin isn't in acme) and two group messages.
  - read state: bob has read general-talk only part of the way, carol is
    notified there for mentions only, and carol stops following a thread.

Test data only: everything is made up, and the instance runs on localhost.
"""

import json
import os
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
import zlib

# docker, or podman (CONTAINER_ENGINE=podman)
ENGINE = os.environ.get("CONTAINER_ENGINE", "docker")
BASE, CONTAINER, PASSWORD = sys.argv[1], sys.argv[2], sys.argv[3]
API = BASE + "/api/v4"


def mmctl(*args):
	r = subprocess.run(
		[ENGINE, "exec", CONTAINER, "mmctl", "--local", *args],
		capture_output=True,
		text=True,
	)
	return (r.stdout + r.stderr).strip()


def call(method, path, token=None, body=None, raw=None, ctype="application/json"):
	data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
	req = urllib.request.Request(API + path, data=data, method=method)
	req.add_header("Content-Type", ctype)
	if token:
		req.add_header("Authorization", "Bearer " + token)
	try:
		with urllib.request.urlopen(req) as resp:
			text = resp.read().decode()
			return resp.headers.get("Token"), (json.loads(text) if text else None)
	except urllib.error.HTTPError as e:
		return None, {"error": e.code, "body": e.read().decode()[:300]}


def check(what, result):
	body = result[1]
	if isinstance(body, dict) and "error" in body:
		print(f"{what}: failed, {body}")
	return body


def multipart(fields, files):
	"""fields: {name: text}; files: [(field, filename, content type, bytes)]."""
	boundary = uuid.uuid4().hex
	out = b""
	for name, value in fields.items():
		out += f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode()
	for field, filename, ctype, data in files:
		out += (
			f'--{boundary}\r\nContent-Disposition: form-data; name="{field}"; filename="{filename}"\r\n'
			f"Content-Type: {ctype}\r\n\r\n"
		).encode()
		out += data + b"\r\n"
	out += f"--{boundary}--\r\n".encode()
	return out, f"multipart/form-data; boundary={boundary}"


def png(width, height, color):
	"""A plain PNG of one colour, so the script needs nothing but Python."""

	def chunk(kind, data):
		c = kind + data
		return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c))

	row = b"\x00" + bytes(color) * width
	return (
		b"\x89PNG\r\n\x1a\n"
		+ chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
		+ chunk(b"IDAT", zlib.compress(row * height))
		+ chunk(b"IEND", b"")
	)


for _ in range(90):
	try:
		urllib.request.urlopen(API + "/system/ping")
		break
	except Exception:
		time.sleep(2)

# Accounts and teams.
PEOPLE = {
	"admin": ["--system-admin", "--nickname", "The Admin"],
	"alice": ["--firstname", "Alice", "--lastname", "Archer"],
	"bob": ["--nickname", "Bobby"],
	"carol": [],
	"dave": ["--firstname", "Dave"],
	"erin": [],
	"frank": ["--firstname", "Frank", "--lastname", "Fisher"],
	"gus": [],
}
for name, extra in PEOPLE.items():
	out = mmctl("user", "create", "--email", f"{name}@example.invalid", "--username", name, "--password", PASSWORD, *extra)
	print(out.splitlines()[-1] if out else name)
print(mmctl("team", "create", "--name", "acme", "--display-name", "Acme"))
print(mmctl("team", "create", "--name", "other", "--display-name", "Other Team", "--private"))
print(mmctl("team", "users", "add", "acme", "admin", "alice", "bob", "carol", "dave", "frank", "gus"))
print(mmctl("team", "users", "add", "other", "admin", "alice", "erin"))

admin = call("POST", "/users/login", body={"login_id": "admin", "password": PASSWORD})[0]
uid = {name: call("GET", f"/users/username/{name}", admin)[1]["id"] for name in PEOPLE}
tok = {name: call("POST", "/users/login", body={"login_id": name, "password": PASSWORD})[0] for name in PEOPLE}
acme = call("GET", "/teams/name/acme", admin)[1]["id"]
other = call("GET", "/teams/name/other", admin)[1]["id"]

# gus is a guest. Mattermost wants a license for that; without one he
# stays a plain member, and the run says so.
check("demote gus to a guest", call("POST", f"/users/{uid['gus']}/demote", admin))
check(
	"alice as team admin",
	call("PUT", f"/teams/{acme}/members/{uid['alice']}/schemeRoles", admin, {"scheme_admin": True, "scheme_user": True}),
)
raw, ctype = multipart({}, [("image", "frank.png", "image/png", png(64, 64, (40, 120, 200)))])
check("frank's picture", call("POST", f"/users/{uid['frank']}/image", tok["frank"], raw=raw, ctype=ctype))

# A custom emoji.
raw, ctype = multipart(
	{"emoji": json.dumps({"name": "partyparrot", "creator_id": uid["alice"]})},
	[("image", "partyparrot.png", "image/png", png(32, 32, (230, 60, 160)))],
)
check("custom emoji", call("POST", "/emoji", tok["alice"], raw=raw, ctype=ctype))

# The bot, with a token to post with.
bot = check("bot", call("POST", "/bots", admin, {"username": "buildbot", "display_name": "Build Bot", "description": "Says how builds went"}))
bot_id = bot["user_id"]
bot_tok = check("bot token", call("POST", f"/users/{bot_id}/tokens", admin, {"description": "seed"}))["token"]
call("POST", f"/teams/{acme}/members", admin, {"team_id": acme, "user_id": bot_id})


def channel(team, name, kind, members, header="", purpose=""):
	c = check(
		f"channel {name}",
		call(
			"POST",
			"/channels",
			admin,
			{"team_id": team, "name": name, "display_name": name.replace("-", " ").title(), "type": kind, "header": header, "purpose": purpose},
		),
	)
	for m in members:
		call("POST", f"/channels/{c['id']}/members", admin, {"user_id": uid[m] if m in uid else m})
	return c["id"]


def by_name(team, name):
	return call("GET", f"/teams/{team}/channels/name/{name}", admin)[1]["id"]


EVERYONE = ["alice", "bob", "carol", "dave", "frank", "gus"]
town = by_name(acme, "town-square")
off = by_name(acme, "off-topic")
pub = channel(acme, "general-talk", "O", EVERYONE + [bot_id], "Talk about *anything*", "The main channel")
priv = channel(acme, "secret", "P", ["alice", "bob"], purpose="Only a purpose, no header")
old = channel(acme, "old-stuff", "O", ["alice", "bob", "carol"])
phoenix = channel(acme, "phoenix", "O", ["alice", "carol"])
elsewhere = channel(other, "elsewhere", "O", ["alice", "erin"], "In the other team")
check(
	"bob as channel admin",
	call("PUT", f"/channels/{pub}/members/{uid['bob']}/schemeRoles", admin, {"scheme_admin": True, "scheme_user": True}),
)


def post(user, ch, text, root="", props=None, files=None, token=None):
	body = {"channel_id": ch, "message": text, "root_id": root}
	if props:
		body["props"] = props
	if files:
		body["file_ids"] = files
	p = check(f"post {text[:30]!r}", call("POST", "/posts", token or tok[user], body))
	# Keeps create_at apart, so the order of the posts is plain.
	time.sleep(0.02)
	return p


def upload(user, ch, filename, ctype, data):
	raw, mp = multipart({"channel_id": ch}, [("files", filename, ctype, data)])
	return check(f"upload {filename}", call("POST", "/files", tok[user], raw=raw, ctype=mp))["file_infos"][0]["id"]


def react(user, post_id, emoji):
	check(f"react {emoji}", call("POST", "/reactions", tok[user], {"user_id": uid[user], "post_id": post_id, "emoji_name": emoji}))


# general-talk: text.
post("alice", town, "Welcome to Acme, everyone!")
post("bob", off, "Anyone seen my stapler?")
post("alice", pub, "Hello @bob and @carol, have a look at ~secret and ~general-talk :smile: :partyparrot:")
post("bob", pub, "Mentioning @dave, who will be gone soon, and @erin from the other team, in ~elsewhere")
post("admin", pub, "@here quick one: standup moved to 10:00")
post("admin", pub, "@channel the office is closed on Friday")
post("admin", pub, "@all please update your profiles")
post(
	"carol",
	pub,
	"Some **Markdown**: _italic_, `code`, ~~struck~~, a [link](https://example.invalid/page) and\n\n"
	"```python\nprint('a code block')\n```\n\n"
	"| a | b |\n| --- | --- |\n| 1 | 2 |\n\n> a quote\n\n- one\n- two",
)
post("frank", pub, "Unicode: Grüße, こんにちは, 🎉👍🏽, and an emoji shortcode with a skin tone :thumbsup_tone3:")
post("bob", pub, "A long one. " + "All work and no play makes Bob a dull boy. " * 380)
check(
	"/me",
	call("POST", "/commands/execute", tok["bob"], {"channel_id": pub, "team_id": acme, "command": "/me waves at everyone"}),
)

# Threads.
root = post("alice", pub, "A thread: what should we have for lunch?")
post("bob", pub, "Pizza", root=root["id"])
post("carol", pub, "Sushi :sushi:", root=root["id"])
post("alice", pub, "Pizza it is, thanks @bob", root=root["id"])
check(
	"carol stops following",
	call("DELETE", f"/users/{uid['carol']}/teams/{acme}/threads/{root['id']}/following", tok["carol"]),
)
gone_root = post("carol", pub, "A root that will be deleted")
post("bob", pub, "A reply to the root that will be deleted", root=gone_root["id"])
post("alice", pub, "Another reply to it", root=gone_root["id"])
check("delete a root", call("DELETE", f"/posts/{gone_root['id']}", tok["carol"]))
kept_root = post("alice", pub, "A root whose reply will be deleted")
gone_reply = post("bob", pub, "A reply that will be deleted", root=kept_root["id"])
post("carol", pub, "A reply that stays", root=kept_root["id"])
check("delete a reply", call("DELETE", f"/posts/{gone_reply['id']}", tok["bob"]))
gone = post("carol", pub, "A post that will be deleted")
check("delete a post", call("DELETE", f"/posts/{gone['id']}", tok["carol"]))

# bob has read up to here.
check("bob reads", call("POST", f"/channels/members/{uid['bob']}/view", tok["bob"], {"channel_id": pub}))

# Edits, pins, saved posts, reactions.
edited = post("carol", pub, "This will be edited")
check("edit", call("PUT", f"/posts/{edited['id']}/patch", tok["carol"], {"message": "This was edited, twice"}))
pinned = post("alice", pub, "Pin and save me")
check("pin", call("POST", f"/posts/{pinned['id']}/pin", tok["alice"]))
for who in ["bob", "carol"]:
	check(
		f"{who} saves",
		call(
			"PUT",
			f"/users/{uid[who]}/preferences",
			tok[who],
			[{"user_id": uid[who], "category": "flagged_post", "name": pinned["id"], "value": "true"}],
		),
	)
for who, emoji in [("bob", "thumbsup"), ("carol", "thumbsup"), ("frank", "heart"), ("bob", "partyparrot"), ("carol", "+1")]:
	react(who, pinned["id"], emoji)
react("alice", root["id"], "pizza")

# Files: a text file, a picture, and two in one post.
notes = upload("alice", pub, "notes.txt", "text/plain", b"some notes\n")
post("alice", pub, "With a file", files=[notes])
pic = upload("frank", pub, "blue.png", "image/png", png(320, 200, (40, 120, 200)))
post("frank", pub, "A picture", files=[pic])
a = upload("bob", pub, "a.txt", "text/plain", b"first\n")
b = upload("bob", pub, "b.csv", "text/csv", b"x,y\n1,2\n")
post("bob", pub, "", files=[a, b])

# The bot, and an incoming webhook.
post("", pub, "Build #41 passed", token=bot_tok)
post("", pub, "Build #42 failed", props={"override_username": "Nightly"}, token=bot_tok)
hook = check("webhook", call("POST", "/hooks/incoming", admin, {"channel_id": pub, "display_name": "CI hook"}))
req = urllib.request.Request(
	BASE + f"/hooks/{hook['id']}",
	method="POST",
	data=json.dumps(
		{
			"text": "Deploy finished",
			"username": "Jenkins",
			"icon_url": "https://example.invalid/jenkins.png",
			"attachments": [
				{
					"fallback": "Deploy of web 1.2.3 finished",
					"color": "#36a64f",
					"pretext": "Deploy report",
					"title": "web 1.2.3",
					"title_link": "https://example.invalid/deploys/123",
					"text": "Everything went *fine*",
					"fields": [{"title": "Env", "value": "staging", "short": True}],
				}
			],
		}
	).encode(),
)
req.add_header("Content-Type", "application/json")
urllib.request.urlopen(req)

# Other channels.
post("alice", priv, "Private hello")
post("alice", old, "Old channel message")
post("carol", phoenix, "Phoenix, before it burns")
post("erin", elsewhere, "Hello from the other team")

# Channel changes, each making a system post.
check("header", call("PUT", f"/channels/{pub}/patch", tok["alice"], {"header": "Talk about *anything* (really)"}))
check("purpose", call("PUT", f"/channels/{pub}/patch", tok["alice"], {"purpose": "The main channel, still"}))
check("rename", call("PUT", f"/channels/{pub}/patch", tok["alice"], {"display_name": "General Talk Renamed"}))
check("leave", call("DELETE", f"/channels/{pub}/members/{uid['frank']}", tok["frank"]))
check("remove", call("DELETE", f"/channels/{pub}/members/{uid['gus']}", tok["bob"]))
check("add", call("POST", f"/channels/{pub}/members", tok["bob"], {"user_id": uid["gus"]}))
check("join", call("POST", f"/channels/{pub}/members", tok["frank"], {"user_id": uid["frank"]}))
check("to private", call("PUT", f"/channels/{pub}/privacy", admin, {"privacy": "P"}))
check("to public", call("PUT", f"/channels/{pub}/privacy", admin, {"privacy": "O"}))
check("archive", call("DELETE", f"/channels/{old}", admin))
check("archive phoenix", call("DELETE", f"/channels/{phoenix}", admin))
check("restore phoenix", call("POST", f"/channels/{phoenix}/restore", admin))
post("carol", phoenix, "Phoenix, risen again")
check("team leave", call("DELETE", f"/teams/{acme}/members/{uid['frank']}", tok["frank"]))
check("team add", call("POST", f"/teams/{acme}/members", admin, {"team_id": acme, "user_id": uid["frank"]}))

# carol only hears about mentions in general-talk.
check(
	"carol's notifications",
	call(
		"PUT",
		f"/channels/{pub}/members/{uid['carol']}/notify_props",
		tok["carol"],
		{"channel_id": pub, "user_id": uid["carol"], "desktop": "mention", "mark_unread": "mention", "push": "mention"},
	),
)

# DMs and group messages.
dm = check("dm", call("POST", "/channels/direct", tok["alice"], [uid["alice"], uid["bob"]]))["id"]
dm_root = post("alice", dm, "A DM, hi Bob")
dm_reply = post("bob", dm, "A reply in a DM thread", root=dm_root["id"])
react("bob", dm_root["id"], "wave")
react("alice", dm_reply["id"], "partyparrot")
self_dm = check("self dm", call("POST", "/channels/direct", tok["alice"], [uid["alice"], uid["alice"]]))["id"]
post("alice", self_dm, "A note to myself")
dave_dm = check("dave dm", call("POST", "/channels/direct", tok["alice"], [uid["alice"], uid["dave"]]))["id"]
post("alice", dave_dm, "Bye Dave")
post("dave", dave_dm, "Bye Alice")
erin_dm = check("erin dm", call("POST", "/channels/direct", tok["alice"], [uid["alice"], uid["erin"]]))["id"]
post("erin", erin_dm, "Erin isn't in acme")
gm = check("gm", call("POST", "/channels/group", tok["alice"], [uid["alice"], uid["bob"], uid["carol"]]))["id"]
gm_root = post("alice", gm, "A group message")
post("carol", gm, "A group reply")
react("carol", gm_root["id"], "smile")
gm4 = check("gm with dave", call("POST", "/channels/group", tok["bob"], [uid["bob"], uid["carol"], uid["dave"], uid["frank"]]))["id"]
post("bob", gm4, "A group message with dave in it")
post("carol", pub, "The last post in general-talk")

# dave leaves the company.
check("deactivate dave", call("DELETE", f"/users/{uid['dave']}", admin))
print("seeded")
