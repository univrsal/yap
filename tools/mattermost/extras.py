#!/usr/bin/env python3
"""
Fetches what Mattermost's export leaves out by mistake, through its REST
API, and writes it next to an unpacked export as extras.jsonl, in the
export's own line format (docs/design/mattermost-import.md, step 6):

  - custom emoji: an export to a zip (what mmctl makes) skips them
    (10.12.4: exportCustomEmoji only writes them when not archiving).
    Each becomes an `emoji` line, with its picture under data/emoji/.
  - reactions to the first post of a DM or group message: the export
    only has them on replies. Each such post becomes a
    `direct_post_reactions` line naming the post the way a direct_post
    does (channel_members, user, create_at), with its reactions.

	tools/mattermost/extras.py <base url> <export dir>

It needs a system admin: MM_TOKEN set to a personal access token, or
MM_LOGIN and MM_PASSWORD.
"""

import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

BASE, OUT = sys.argv[1].rstrip("/"), Path(sys.argv[2])
API = BASE + "/api/v4"
PAGE = 200


def request(method, path, token=None, body=None):
	req = urllib.request.Request(API + path, data=json.dumps(body).encode() if body is not None else None, method=method)
	req.add_header("Content-Type", "application/json")
	if token:
		req.add_header("Authorization", "Bearer " + token)
	try:
		resp = urllib.request.urlopen(req)
	except urllib.error.HTTPError as e:
		sys.exit(f"{method} {path}: {e.code} {e.read().decode()[:300]}")
	with resp:
		return resp.headers, resp.read()


def get(path):
	return json.loads(request("GET", path, TOKEN)[1])


def pages(path):
	sep = "&" if "?" in path else "?"
	page = 0
	while True:
		items = get(f"{path}{sep}page={page}&per_page={PAGE}")
		yield from items
		if len(items) < PAGE:
			return
		page += 1


TOKEN = os.environ.get("MM_TOKEN")
if not TOKEN:
	login, password = os.environ.get("MM_LOGIN"), os.environ.get("MM_PASSWORD")
	if not login or not password:
		sys.exit("set MM_TOKEN, or MM_LOGIN and MM_PASSWORD")
	headers, _ = request("POST", "/users/login", body={"login_id": login, "password": password})
	TOKEN = headers.get("Token")

lines = []

# Custom emoji.
for emoji in pages("/emoji?sort=name"):
	_, image = request("GET", f"/emoji/{emoji['id']}/image", TOKEN)
	path = Path("emoji") / emoji["id"] / "image"
	(OUT / "data" / path).parent.mkdir(parents=True, exist_ok=True)
	(OUT / "data" / path).write_bytes(image)
	lines.append({"type": "emoji", "emoji": {"name": emoji["name"], "image": path.as_posix()}})

# Reactions to the first post of DMs and group messages. Every DM or group
# shows up in the channels of each of its members, in any of their teams.
users = {u["id"]: u for u in pages("/users?active=true")} | {u["id"]: u for u in pages("/users?inactive=true")}
direct = {}
for user in users.values():
	for team in get(f"/users/{user['id']}/teams"):
		for ch in get(f"/users/{user['id']}/teams/{team['id']}/channels?include_deleted=true"):
			if ch["type"] in ("D", "G"):
				direct[ch["id"]] = ch
for ch in direct.values():
	members = [users[m["user_id"]]["username"] for m in pages(f"/channels/{ch['id']}/members") if m["user_id"] in users]
	if ch["type"] == "D" and len(members) == 1:
		members *= 2  # a DM with oneself, as the export writes it
	seen = set()
	page = 0
	while True:
		got = get(f"/channels/{ch['id']}/posts?page={page}&per_page={PAGE}")
		for post_id in got["order"]:
			post = got["posts"][post_id]
			if post_id in seen or post["root_id"] or post["delete_at"]:
				continue
			seen.add(post_id)
			reactions = post.get("metadata", {}).get("reactions") or []
			reactions = [r for r in reactions if r["user_id"] in users]
			if not reactions or post["user_id"] not in users:
				continue
			lines.append(
				{
					"type": "direct_post_reactions",
					"direct_post_reactions": {
						"channel_members": members,
						"user": users[post["user_id"]]["username"],
						"create_at": post["create_at"],
						"reactions": [
							{"user": users[r["user_id"]]["username"], "emoji_name": r["emoji_name"], "create_at": r["create_at"]}
							for r in reactions
						],
					},
				}
			)
		if len(got["order"]) < PAGE:
			break
		page += 1

with open(OUT / "extras.jsonl", "w", encoding="utf-8", newline="\n") as f:
	for line in lines:
		f.write(json.dumps(line, ensure_ascii=False) + "\n")
print(f"{len(lines)} lines in {OUT / 'extras.jsonl'}")
