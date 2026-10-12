"""A dice bot for DMs: "!roll 2d6" answers with the throw.

    pip install requests websockets
    YAP_URL=http://localhost:8080 YAP_TOKEN=yap_... python roll.py

Anyone may DM a bot. This one keeps track of which conversations are DMs
(READY, then CONV_UPDATE as new ones come), shows it's typing, and
answers in the DM only.
"""

import asyncio
import json
import os
import random
import re

import requests
import websockets

API = os.environ.get("YAP_URL", "http://localhost:8080").rstrip("/") + "/api/v1"
TOKEN = os.environ["YAP_TOKEN"]
HEADERS = {"Authorization": f"Bot {TOKEN}"}
ROLL = re.compile(r"^!roll\s+(\d{1,2})d(\d{1,4})\s*$")


def answer(conv_id, text):
    count, sides = (int(n) for n in ROLL.match(text).groups())
    if not 1 <= count <= 20 or not 2 <= sides <= 1000:
        reply = "I roll 1 to 20 dice of 2 to 1000 sides."
    else:
        throws = [random.randint(1, sides) for _ in range(count)]
        reply = f"**{sum(throws)}** ({' + '.join(map(str, throws))})"
    requests.post(f"{API}/convs/{conv_id}/typing", headers=HEADERS)
    requests.post(
        f"{API}/convs/{conv_id}/messages", headers=HEADERS, json={"content": reply}
    ).raise_for_status()
    # And it's read, so the conversation doesn't show as unread.
    requests.post(f"{API}/convs/{conv_id}/read", headers=HEADERS)


async def main():
    me = None
    dms = set()
    async with websockets.connect(API.replace("http", "ws", 1) + f"/events?token={TOKEN}") as ws:
        async for frame in ws:
            event = json.loads(frame)
            kind, d = event["t"], event["d"]
            if kind == "READY":
                me = d["me"]["id"]
                dms = {c["id"] for c in d["convs"] if c["kind"] == "dm"}
                print(f"ready as {d['me']['username']}, with {len(dms)} DMs")
            elif kind == "CONV_UPDATE" and d["kind"] == "dm":
                dms.add(d["id"])
            elif kind == "MESSAGE_CREATE":
                if d["conv_id"] in dms and d["author"]["id"] != me and ROLL.match(d["content"]):
                    answer(d["conv_id"], d["content"])


if __name__ == "__main__":
    asyncio.run(main())
