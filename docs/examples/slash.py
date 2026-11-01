"""A bot with slash commands: /roll 2d6, /echo <text> and /ping.

    pip install requests websockets
    YAP_URL=http://localhost:8080 YAP_TOKEN=yap_... python slash.py

The bot registers its commands with PUT /commands, which everyone is then
offered while typing a "/". Running one reaches the bot as a COMMAND event,
and it answers with an ordinary post, in the same thread if there is one.

The commands go when the bot's connection does, so they are set again after
every READY. If another bot has a command with the same name, people type
/<this bot's username>:roll to pick this one.
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
DICE = re.compile(r"^(\d{1,2})d(\d{1,4})$")

COMMANDS = [
    {"name": "roll", "description": "Roll dice", "usage": "<n>d<sides>"},
    {"name": "echo", "description": "Say something back", "usage": "<text>"},
    {"name": "ping", "description": "Check that the bot is there"},
]


def roll(args):
    m = DICE.match(args.strip())
    if not m:
        return "Say how many dice and how many sides, like `/roll 2d6`."
    count, sides = int(m[1]), int(m[2])
    if not 1 <= count <= 20 or not 2 <= sides <= 1000:
        return "I roll 1 to 20 dice of 2 to 1000 sides."
    throws = [random.randint(1, sides) for _ in range(count)]
    return f"**{sum(throws)}** ({' + '.join(map(str, throws))})"


def answer(name, args, user):
    if name == "roll":
        return roll(args)
    if name == "echo":
        return args or "There is nothing to echo. Try `/echo hello`."
    if name == "ping":
        return f"Pong, {user['display'] or user['username']}."
    return None


def register():
    """Set this bot's commands, replacing any it had."""
    r = requests.put(f"{API}/commands", headers=HEADERS, json=COMMANDS)
    r.raise_for_status()
    print("commands set:", ", ".join("/" + c["name"] for c in r.json()["commands"]))


def handle(command):
    reply = answer(command["name"], command["args"], command["user"])
    if reply is None:
        return
    r = requests.post(
        f"{API}/convs/{command['conv_id']}/messages",
        headers=HEADERS,
        # `thread` is the root message's id when the command was run in a thread.
        json={"content": reply, "thread": command["thread"]},
    )
    if not r.ok:
        # Posting is checked like anyone's: the bot may have lost the right to write here.
        print("could not answer:", r.status_code, r.text)


async def main():
    while True:
        try:
            async with websockets.connect(API.replace("http", "ws", 1) + f"/events?token={TOKEN}") as ws:
                async for frame in ws:
                    event = json.loads(frame)
                    if event["t"] == "READY":
                        # Also after a reconnect: the commands went with the old connection.
                        await asyncio.to_thread(register)
                    elif event["t"] == "COMMAND":
                        await asyncio.to_thread(handle, event["d"])
        except (OSError, websockets.ConnectionClosed) as e:
            print("disconnected:", e, "- trying again in 5 seconds")
            await asyncio.sleep(5)


if __name__ == "__main__":
    asyncio.run(main())
