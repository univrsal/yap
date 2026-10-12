"""An echo bot: answers "!echo <text>" with <text>, wherever it's said.

    pip install requests websockets
    YAP_URL=http://localhost:8080 YAP_TOKEN=yap_... python echo.py

It listens on the event socket, posts with the REST API, and picks up
where it left off when the socket drops (?resume=).
"""

import asyncio
import json
import os
import time

import requests
import websockets

API = os.environ.get("YAP_URL", "http://localhost:8080").rstrip("/") + "/api/v1"
TOKEN = os.environ["YAP_TOKEN"]
HEADERS = {"Authorization": f"Bot {TOKEN}"}


def post(conv_id, content, thread=None):
    """Post a message, waiting out a rate limit if there is one."""
    while True:
        r = requests.post(
            f"{API}/convs/{conv_id}/messages",
            headers=HEADERS,
            json={"content": content, "thread": thread},
        )
        if r.status_code != 429:
            r.raise_for_status()
            return r.json()
        time.sleep(int(r.headers.get("Retry-After", "1")))


async def main():
    me = None
    last = None  # the last event's number, to resume from
    # The token in the URL works with every version of `websockets`; a
    # header (Authorization: Bot ...) would do too.
    events = API.replace("http", "ws", 1) + f"/events?token={TOKEN}"
    while True:
        url = events if last is None else f"{events}&resume={last}"
        try:
            async with websockets.connect(url) as ws:
                async for frame in ws:
                    event = json.loads(frame)
                    last = event["s"]
                    kind, d = event["t"], event["d"]
                    if kind == "READY":
                        me = d["me"]["id"]
                        print(f"ready as {d['me']['username']}, in {len(d['convs'])} conversations")
                    elif kind == "MESSAGE_CREATE":
                        text = d["content"]
                        if d["author"]["id"] != me and text.startswith("!echo "):
                            post(d["conv_id"], text[len("!echo "):], d["thread"])
        except websockets.ConnectionClosed as closed:
            code = closed.rcvd.code if closed.rcvd else None
            if code in (4000, 4001):
                # Another copy of the bot took over, or the token stopped
                # working: either way, this one is done.
                print(f"closed ({code}): {closed.rcvd.reason}")
                return
        except OSError as e:
            print(f"can't reach the API: {e}")
        await asyncio.sleep(2)


if __name__ == "__main__":
    asyncio.run(main())
