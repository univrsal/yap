"""Posting under other names: one bot, many personas.

    pip install requests
    YAP_URL=http://localhost:8080 YAP_TOKEN=yap_... python persona.py 1 build.jpg

A persona is a name and a picture that one message is shown under, as a CI
bot does for each project or a bridge for each person it relays. The
message is still the bot's: clients show the bot's tag and "via <bot>"
next to the name, and replies and mentions go to the bot. The name may not
be any account's username or display name (403).

The first argument is the conversation's id; the second, optional, is a
JPEG of at most 256 pixels per side and 64 KB, used as the picture.
"""

import os
import sys

import requests

API = os.environ.get("YAP_URL", "http://localhost:8080").rstrip("/") + "/api/v1"
HEADERS = {"Authorization": f"Bot {os.environ['YAP_TOKEN']}"}


def upload_picture(path):
    """Upload a JPEG for personas and return its id. The server removes a
    picture that no message uses within an hour, so upload it once and post
    soon, or upload it again."""
    with open(path, "rb") as f:
        r = requests.post(f"{API}/avatars", headers=HEADERS, data=f.read())
    r.raise_for_status()
    return r.json()["id"]


def post_as(conv_id, name, content, avatar=None):
    persona = {"name": name}
    if avatar:
        persona["avatar"] = avatar
    r = requests.post(
        f"{API}/convs/{conv_id}/messages",
        headers=HEADERS,
        json={"content": content, "persona": persona},
    )
    r.raise_for_status()
    return r.json()


conv = sys.argv[1]
avatar = sys.argv[2] if len(sys.argv) > 2 else "./clippy.jpg"
print(avatar)
picture = upload_picture(avatar)

# The picture belongs to the first persona only; the others get a disc with
# the name's first letter.
post_as(conv, "Build Server #123", "Build 123 passed", picture)
post_as(conv, "Deploy Bot", "Deployed to staging")
message = post_as(conv, "Deploy Bot", "Deployed to production")

# The message object says who it was posted as and by whom.
print(message["persona"], "via", message["author"]["username"])
