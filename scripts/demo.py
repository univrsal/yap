#!/usr/bin/env python3
"""
Sets up a demo yap server: a consistent environment for screenshots and testing.

	scripts/demo.py             make it (the first time) and run it
	scripts/demo.py --reset     throw the data away and make it again

What it makes, in ./demo-server/ (use --dir for another place):

  - a server called "Yap Demo" on UDP 17777, with the web relay and the bot API
    on 18080 (so the web client works too, if web/out is built),
  - 10 accounts, roles, channels (public, private, text-only, archived), DMs,
    about 150 messages spread over the last days with threads, mentions,
    reactions, pins, edits, markdown, pictures and files,
  - 3 bots (weather, ci, dice) that have posted, one under personas,
  - two accounts for you to log in with, which nobody has read for yet, so they
    have unread counts and a mention:

        admin   /  demodemo     the server's owner
        demo    /  demodemo     an ordinary member

  - while it runs, headless clients (bin/yap -headless) log in as some of the
    others: they show as online or away or busy, and three of them sit in the
    voice rooms of #dev and #music, two with a tone as their microphone (so
    they show as talking) and one muted.

Ctrl+C stops the clients and the server. Run it again without --reset and the
same data is served again (the accounts' device keys are kept in demo-server/keys).

Needs bin/yap and bin/yap-server (./build.sh), Python 3 and Pillow (pip install
pillow) for the pictures. Nothing else is touched: bin/config.json and your own
settings are left alone. The messages' times are set by editing the database
while the server is stopped (see backdate), so they read like a few days of
use rather than one minute.
"""

import argparse
import colorsys
import io
import json
import math
import os
import random
import re
import signal
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    sys.exit("demo.py needs Pillow for the pictures: pip install pillow")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PASSWORD = "demodemo"
SERVER_NAME = "Yap Demo"
MUST_CHANGE = 4  # proto.Account_Flag.Must_Change

# ----------------------------------------------------------------------------
# What the server is filled with.

# username, display name, picture colour (hue 0-1), status line, activity,
# and where they are while the demo runs: None (offline), or
# (activity, voice channel or None, tone in Hz or 0 for muted).
PEOPLE = [
    ("alice", "Alice Chen", 0.58, "Reviewing PRs", "online", ("online", "dev", 440)),
    ("bob", "Bob Martinez", 0.08, "", "online", ("online", "dev", 0)),
    ("carol", "Carol Okafor", 0.83, "Writing docs", "online", ("online", "music", 330)),
    ("dave", "Dave Lindqvist", 0.35, "", "online", ("online", None, 0)),
    ("erin", "Erin Walsh", 0.14, "Back in 10 minutes", "away", ("away", None, 0)),
    ("frank", "Frank Moreau", 0.0, "In a meeting", "busy", ("busy", None, 0)),
    ("grace", "Grace Kim", 0.70, "", "online", None),
    ("heidi", "Heidi Sato", 0.48, "On holiday until Monday", "away", None),
    ("demo", "Demo User", 0.95, "", "online", None),
]
ADMIN = ("admin", "Admin", 0.62)
BOTS = [  # username, display, hue
    ("weather", "Weather Bot", 0.55),
    ("ci", "CI", 0.30),
    ("dice", "Dice", 0.0),
]
ROLES = {  # name: (permissions, members)
    "Moderators": ("Manage_Messages,Pin_Messages,Move_Members,Mute_Members,Ban_Members", ["alice", "carol"]),
    "Developers": ("Pin_Messages,Create_Channels", ["bob", "dave", "alice"]),
}
# name, topic, kind (None, "text-only", "private", "archived"), members of a
# private one, who joins (everyone: all accounts), and how long ago its
# messages go back (days) and end (minutes).
CHANNELS = [
    ("Lobby", "Welcome to the Yap demo server. Say hi!", None, "everyone", (4, 14)),
    ("announcements", "News about the server. Read only", "text-only", "everyone", (12, 600)),
    ("general", "Everything that has no other place", None, "everyone", (4, 22)),
    ("dev", "Code, builds and bugs", None, ["admin", "alice", "bob", "dave", "frank", "demo"], (3, 8)),
    ("design", "UI, icons and colours", None, ["admin", "carol", "erin", "grace", "heidi", "demo"], (5, 160)),
    ("random", "Photos, links, whatever", None, "everyone", (3, 41)),
    ("music", "Hang out and listen", None, ["admin", "carol", "dave", "grace", "demo"], (3, 75)),
    ("staff", "Moderators and admins", "private", ["admin", "alice", "carol"], (3, 300)),
    ("old-project", "Archived", "archived", ["admin", "bob", "dave"], (30, 60 * 24 * 12)),
]
# Where the bots are (the home channel, Lobby, has everyone).
SUBSCRIBERS = {"weather": ["general", "random"], "dice": ["music", "random"], "ci": ["dev"]}
DMS = {  # (a, b): (days, minutes since the last message)
    ("alice", "demo"): (2, 35),
    ("bob", "demo"): (4, 60 * 20),
    ("alice", "bob"): (2, 120),
}


def M(who, text="", react=None, pin=False, img=None, file=None, replies=None, persona=None):
    """One message. `react` maps an emoji to who reacted, `img` and `file` name
    an attachment (see IMAGES and FILES), `replies` is a thread."""
    return dict(
        who=who, text=text, react=react or {}, pin=pin, img=img, file=file,
        replies=replies or [], persona=persona,
    )


CHAT = {
    "Lobby": [
        M("admin", "Welcome to **Yap Demo**! :tada: This server is full of made-up people and messages for screenshots and testing.",
          react={"🎉": ["alice", "bob", "carol", "dave"], "👋": ["erin", "grace", "frank"]}, pin=True),
        M("alice", "Hi everyone! Glad we finally moved over from the old chat."),
        M("bob", "Same here. The voice rooms are so much better than what we had", react={"💯": ["alice", "carol"]}),
        M("carol", "Quick reminder: the **design review** is tomorrow at 10:00. Join the voice room in #design if you can't make it in person."),
        M("dave", "can someone point me to the build instructions?",
          replies=[
              M("bob", "It's in the docs folder, `docs/Building.md`"),
              M("dave", "Found it, thanks!"),
              M("alice", "Tip: `./build.sh` does the server and the client in one go.", react={"💡": ["dave"]}),
          ]),
        M("erin", "Good morning! :coffee:"),
        M("weather", "**Good morning!** Today in Berlin: ☀️ 14°C, light wind from the west. Sunset at 16:41.", react={"☀️": ["erin", "grace"]}),
        M("grace", "Does anyone know if the office is open on Friday?"),
        M("frank", "Yes, but only until 14:00."),
        M("grace", "Perfect, thanks Frank", react={"👍": ["frank"]}),
        M("heidi", "Greetings from the beach 🏖️ See you all on Monday!", img="beach",
          react={"😍": ["alice", "carol", "erin", "bob"], "🌊": ["grace"]}),
        M("alice", "@demo welcome aboard! Let us know if something looks off."),
    ],
    "announcements": [
        M("admin", "# Server update\nWe moved to the new server today. **What's new:**\n\n- Voice rooms in every channel\n- Message reactions and threads\n- Markdown in messages\n- Pictures and files\n\nHave fun!",
          pin=True, react={"🎉": ["alice", "bob", "carol", "dave", "erin"], "❤️": ["grace", "heidi"]}),
        M("admin", "Maintenance window on **Sunday, 03:00 to 03:30 UTC**. The server will restart once.", react={"👍": ["alice", "bob"]}),
        M("admin", "Reminder: please set a profile picture. It helps everyone find each other in a busy channel."),
        M("admin", "New channel: #music. Bring your own playlist :musical_note:", react={"🎵": ["carol", "dave", "grace"]}),
    ],
    "general": [
        M("carol", "Morning all. Anyone up for lunch at the new ramen place?", react={"🍜": ["bob", "dave", "erin"]}),
        M("bob", "Count me in!"),
        M("dave", "Me too. 12:30?"),
        M("carol", "12:30 works.", react={"👍": ["dave", "bob"]}),
        M("erin", "I'll join if there is a vegetarian option"),
        M("carol", "There is, I checked. Two of them."),
        M("frank", "Quick poll: standup at 9:30 or 10:00 from next week?",
          replies=[
              M("alice", "9:30 is fine for me"),
              M("bob", "10:00 please, I commute"),
              M("dave", "10:00 :+1:"),
              M("erin", "10:00"),
              M("frank", "10:00 it is. I'll update the calendar."),
          ], react={"👍": ["dave", "erin", "bob"], "👎": ["alice"]}),
        M("grace", "Has anyone seen my notebook? Black cover, stickers all over it"),
        M("heidi", "It's on the shelf next to the printer, I put it there on Tuesday"),
        M("grace", "You're a star :star:", react={"⭐": ["heidi"]}),
        M("alice", "@demo could you have a look at the **onboarding checklist** when you have a minute? 🙏", react={"🙏": ["demo"]}),
        M("weather", "**Forecast for Berlin**\n\n| Day | Weather | High | Low |\n| --- | --- | --- | --- |\n| Mon | ☀️ Sunny | 15° | 6° |\n| Tue | ⛅ Cloudy | 13° | 7° |\n| Wed | 🌧️ Rain | 11° | 8° |\n| Thu | 🌧️ Rain | 10° | 7° |\n| Fri | ⛅ Cloudy | 12° | 5° |"),
        M("bob", "Wednesday lunch is going to be indoors then"),
    ],
    "dev": [
        M("alice", "Heads up: I'm about to merge the **reconnect** branch. It retries lost servers every 30 seconds.",
          react={"🚀": ["bob", "dave"], "👀": ["frank"]}),
        M("bob", "Nice. Did you test the case where the server comes back with a new key?"),
        M("alice", "Yes, it asks to trust it again, like on first connect."),
        M("ci", "Build **#412** for `reconnect` passed in 4m 12s", file="build.log", persona=("GitHub", "gh"),
          react={"✅": ["alice"]}),
        M("dave", "Found something odd while testing. Steps to reproduce:\n\n1. Join a voice room\n2. Switch servers\n3. Switch back\n\nThe mute button shows the wrong state.",
          img="mockup", react={"🐛": ["bob", "alice"]},
          replies=[
              M("bob", "I can reproduce it. Looks like the state is read before the server confirms."),
              M("alice", "I'll take it. Here's the fix:\n\n```odin\nif !conn.voice.confirmed {\n\tdraw_mute_pending(ui)\n\treturn\n}\n```\n\nI'll push it in a minute."),
              M("dave", "Thanks Alice! 🎉"),
          ]),
        M("frank", "Do we want to bump the protocol version for this?"),
        M("bob", "No, it's client-side only."),
        M("ci", "Build **#413** for `mute-state` ❌ failed after 1m 03s\n\n```\ntests/voice_test.odin(88): expected Muted, got Unmuted\n```", persona=("GitHub", "gh"),
          react={"😬": ["alice", "dave"]}),
        M("alice", "Oops. Missed one test, fixing."),
        M("ci", "Build **#414** for `mute-state` passed in 3m 58s", persona=("GitHub", "gh"), react={"✅": ["alice", "bob", "dave"]}),
        M("ci", "Deployed **v1.4.1** to `staging`", persona=("Deploy Bot", "deploy"), react={"🚢": ["frank"]}),
        M("alice", "```sh\n$ yap-server\n2026-11-09 09:41:03 INFO  listening on udp :7777\n2026-11-09 09:41:03 INFO  server public key: 55436147e255...\n```\nThe log looks clean now.", react={"👍": ["bob"]}),
        M("bob", "Anyone free for a quick pairing session? Voice room is open.", react={"🎧": ["alice"]}),
    ],
    "design": [
        M("carol", "First draft of the new **settings page**. Feedback welcome!", img="dashboard",
          react={"🔥": ["erin", "grace"], "💜": ["heidi"]}, pin=True),
        M("erin", "Love the spacing. The grey on grey for disabled items is a bit hard to read though."),
        M("carol", "Good catch. I'll bump the contrast.", react={"👍": ["erin"]}),
        M("grace", "What about the icon set? Still outlined or switching to filled?",
          replies=[
              M("carol", "Outlined, 1.5px stroke. Filled looks too heavy next to the text."),
              M("erin", "Agreed, outlined."),
          ]),
        M("heidi", "Colour palette I put together over the weekend:", img="palette", react={"🎨": ["carol", "erin"]}),
        M("carol", "That blue is gorgeous. Can we use it for the accent colour?"),
        M("heidi", "That was the plan 😄"),
        M("erin", "Reminder: the review is at 10:00 tomorrow, voice room in this channel."),
    ],
    "random": [
        M("dave", "Look what I found in the garage", img="mountain", react={"😮": ["bob", "carol", "erin"], "🏔️": ["alice"]}),
        M("bob", "Where is that??"),
        M("dave", "Norway, last summer. Best hike I ever did."),
        M("erin", "TIL: octopuses have three hearts 🐙", react={"😲": ["dave", "grace"], "🐙": ["bob"]}),
        M("grace", "Two of them pump blood to the gills, the third to the rest of the body."),
        M("alice", "Reading list for the weekend:\n\n- [The Pragmatic Programmer](https://pragprog.com/titles/tpp20/)\n- [Designing Data-Intensive Applications](https://dataintensive.net/)\n- Something that is not about work"),
        M("weather", "**Weekend outlook:** ☀️ Saturday 17°C, ⛅ Sunday 14°C. Good day for a walk!", react={"🚶": ["grace", "dave"]}),
        M("dave", "!roll 2d6"),
        M("dice", "🎲 **dave** rolled `2d6`: 4 + 5 = **9**", react={"🎲": ["dave", "bob"]}),
        M("bob", "!roll 1d20"),
        M("dice", "🎲 **bob** rolled `1d20`: **20**. Critical hit! 🎉", react={"🎉": ["bob", "dave", "alice"], "😱": ["erin"]}),
        M("frank", "This sunset though 🌅", img="sunset", react={"🌅": ["alice", "carol", "grace", "heidi"], "😍": ["erin"]}),
    ],
    "music": [
        M("carol", "Current rotation: lo-fi beats for the afternoon 🎧", react={"🎶": ["dave", "grace"]}),
        M("dave", "Can we have some actual synths please"),
        M("carol", "Queue is open: send me your song of the day."),
        M("grace", "Bonobo - Kerala. Always.", react={"💯": ["carol", "dave"]}),
        M("dice", "🎲 **carol** rolled `1d6` to pick the next genre: **4** (jazz) 🎷"),
        M("dave", "Jazz it is.", react={"🎷": ["carol", "grace"]}),
    ],
    "staff": [
        M("alice", "Heads up, I muted a spammer in #general for an hour. Nothing else needed."),
        M("carol", "Thanks. Do we want to add a rule about link spam to the pinned message?"),
        M("admin", "Yes please. Draft it here and I'll pin it.", react={"👍": ["alice", "carol"]}),
        M("carol", "**Draft:**\n\n1. Be kind\n2. No spam or unsolicited links\n3. Keep voice rooms on topic", pin=True),
    ],
    "old-project": [
        M("bob", "Final handover notes are in the wiki. Closing this channel."),
        M("dave", "Thanks for all the work on this one :heart:", react={"❤️": ["bob"]}),
    ],
}

DM_CHAT = {
    ("alice", "demo"): [
        M("alice", "Hey! Did you get a chance to look at the onboarding checklist?"),
        M("alice", "No rush, just checking 🙂"),
        M("alice", "Also: lunch tomorrow? We're going to the ramen place.", react={"🍜": ["alice"]}),
    ],
    ("bob", "demo"): [
        M("bob", "Welcome! If you have questions about the build, just ask."),
        M("demo", "Thanks Bob, will do!"),
        M("bob", "Here's the log of the last build in case you need it.", file="build.log"),
        M("demo", "Perfect, that helps a lot.", react={"👍": ["bob"]}),
    ],
    ("alice", "bob"): [
        M("alice", "Can you review my PR?"),
        M("bob", "On it. Give me 20 minutes."),
    ],
}

# Messages edited after they were posted: (channel, text) -> the new text.
EDITS = {
    ("general", "Quick poll: standup at 9:30 or 10:00 from next week?"): "Quick poll: standup at 9:30 or 10:00 from next week? Vote with a reaction.",
    ("Lobby", "Hi everyone! Glad we finally moved over from the old chat."): "Hi everyone! Glad we finally moved over from the old chat. :tada:",
}

FILES = {
    "build.log": (
        "build.log",
        "[09:12:01] cloning repository\n[09:12:04] odin build src/server -out:bin/yap-server\n[09:13:17] odin build src/client -out:bin/yap\n"
        "[09:15:22] running tests: 412 passed, 0 failed\n[09:16:13] done in 4m12s\n",
    ),
}

# The API takes ":name:" for the server's own emoji only, so these are spelled out.
SHORTCODES = {":tada:": "🎉", ":coffee:": "☕", ":+1:": "👍", ":musical_note:": "🎵", ":heart:": "❤️", ":star:": "⭐"}


def shortcodes(text):
    for code, emoji in SHORTCODES.items():
        text = text.replace(code, emoji)
    return text


def mentions(text, ids):
    """@username as the mention token that the server records (<@17>)."""
    return re.sub(r"@(\w+)", lambda m: f"<@{ids[m.group(1)]}>" if m.group(1) in ids else m.group(0), text)


# ----------------------------------------------------------------------------
# Pictures.


def font(size):
    for path in ("/usr/share/fonts/TTF/DejaVuSans.ttf", "/usr/share/fonts/dejavu/DejaVuSans.ttf",
                 "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/Library/Fonts/Arial.ttf"):
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default(size)


def rgb(h, s, v):
    r, g, b = colorsys.hsv_to_rgb(h, s, v)
    return (int(r * 255), int(g * 255), int(b * 255))


def encode(img, fmt="PNG"):
    out = io.BytesIO()
    if fmt == "JPEG":
        img.convert("RGB").save(out, "JPEG", quality=86)
    else:
        img.save(out, "PNG", optimize=True)
    return out.getvalue()


def sky(w, h, top, bottom):
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / (h - 1)
        d.line([(0, y), (w, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return img


def ridge(d, w, h, base, amp, color, seed, step=8):
    r = random.Random(seed)
    phases = [r.uniform(0, 6.28) for _ in range(3)]
    pts = [(0, h)]
    for x in range(0, w + step, step):
        y = base + amp * (0.5 * math.sin(x / 130 + phases[0]) + 0.3 * math.sin(x / 57 + phases[1]) + 0.2 * math.sin(x / 23 + phases[2]))
        pts.append((x, y))
    pts.append((w, h))
    d.polygon(pts, fill=color)


def pic_sunset():
    w, h = 960, 600
    img = sky(w, h, (38, 28, 82), (255, 150, 80))
    d = ImageDraw.Draw(img)
    d.ellipse([w // 2 - 70, 330, w // 2 + 70, 470], fill=(255, 226, 150))
    ridge(d, w, h, 430, 40, (70, 40, 90), 1)
    ridge(d, w, h, 490, 50, (36, 24, 60), 2)
    ridge(d, w, h, 560, 30, (16, 12, 30), 3)
    return "sunset.jpg", encode(img, "JPEG")


def pic_mountain():
    w, h = 960, 640
    img = sky(w, h, (110, 170, 230), (225, 240, 250))
    d = ImageDraw.Draw(img)
    ridge(d, w, h, 300, 140, (150, 165, 190), 11, 4)
    ridge(d, w, h, 380, 110, (96, 120, 140), 12, 4)
    ridge(d, w, h, 470, 70, (50, 90, 70), 13, 4)
    ridge(d, w, h, 560, 40, (28, 62, 44), 14, 4)
    return "norway.jpg", encode(img, "JPEG")


def pic_beach():
    w, h = 960, 600
    img = sky(w, h, (90, 170, 235), (200, 235, 250))
    d = ImageDraw.Draw(img)
    d.ellipse([740, 60, 840, 160], fill=(255, 245, 190))
    d.rectangle([0, 320, w, 420], fill=(40, 140, 190))
    for i in range(6):
        d.line([(0, 330 + i * 15), (w, 330 + i * 15)], fill=(70, 170, 210), width=2)
    ridge(d, w, h, 440, 12, (238, 214, 160), 21, 4)
    d.polygon([(0, 600), (0, 470), (w, 520), (w, 600)], fill=(230, 204, 150))
    d.line([(150, 560), (150, 430)], fill=(110, 80, 50), width=8)
    d.polygon([(150, 435), (60, 400), (80, 380)], fill=(40, 120, 70))
    d.polygon([(150, 435), (240, 400), (220, 380)], fill=(40, 120, 70))
    d.polygon([(150, 430), (150, 360), (180, 390)], fill=(50, 140, 80))
    return "holiday.jpg", encode(img, "JPEG")


def pic_dashboard():
    w, h = 1000, 640
    img = Image.new("RGB", (w, h), (24, 26, 33))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, 200, h], fill=(32, 35, 44))
    d.text((24, 22), "Settings", fill=(235, 238, 245), font=font(24))
    for i, label in enumerate(["Account", "Audio", "Video", "Appearance", "Notifications", "Scripts", "Memory"]):
        y = 80 + i * 44
        if i == 3:
            d.rounded_rectangle([12, y - 8, 188, y + 30], 8, fill=(54, 72, 140))
        d.text((28, y), label, fill=(235, 238, 245) if i == 3 else (150, 156, 172), font=font(17))
    d.text((240, 26), "Appearance", fill=(235, 238, 245), font=font(26))
    for row, (label, on) in enumerate([("Dark theme", True), ("Compact messages", False), ("Show timestamps", True), ("Animate pictures", True)]):
        y = 100 + row * 66
        d.rounded_rectangle([240, y, 960, y + 52], 10, fill=(36, 39, 49))
        d.text((262, y + 14), label, fill=(225, 228, 236), font=font(18))
        d.rounded_rectangle([890, y + 14, 940, y + 38], 12, fill=(70, 110, 240) if on else (70, 74, 90))
        x = 918 if on else 896
        d.ellipse([x, y + 17, x + 18, y + 35], fill=(255, 255, 255))
    d.text((240, 380), "Accent colour", fill=(225, 228, 236), font=font(18))
    for i, hue in enumerate([0.60, 0.45, 0.10, 0.0, 0.80]):
        x = 240 + i * 64
        d.ellipse([x, 420, x + 48, 468], fill=rgb(hue, 0.65, 0.95), outline=(255, 255, 255) if i == 0 else None, width=3)
    d.text((240, 500), "Message size", fill=(225, 228, 236), font=font(18))
    d.rounded_rectangle([240, 545, 760, 553], 4, fill=(70, 74, 90))
    d.rounded_rectangle([240, 545, 520, 553], 4, fill=(70, 110, 240))
    d.ellipse([508, 537, 532, 561], fill=(255, 255, 255))
    return "settings-draft.png", encode(img)


def pic_mockup():
    w, h = 900, 520
    img = Image.new("RGB", (w, h), (28, 30, 38))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, w, 44], fill=(38, 41, 52))
    d.text((16, 10), "Voice - dev", fill=(235, 238, 245), font=font(20))
    for i, (name, muted) in enumerate([("alice", False), ("bob", True), ("dave", False)]):
        y = 80 + i * 90
        d.ellipse([40, y, 100, y + 60], fill=rgb(0.2 + i * 0.25, 0.5, 0.85))
        d.text((120, y + 18), name, fill=(235, 238, 245), font=font(22))
        icon = (230, 80, 80) if muted else (80, 200, 120)
        d.ellipse([w - 120, y + 16, w - 88, y + 48], fill=icon)
        if muted:
            d.line([(w - 116, y + 44), (w - 92, y + 20)], fill=(255, 255, 255), width=4)
    d.rounded_rectangle([40, 400, 420, 460], 10, fill=(70, 110, 240))
    d.text((70, 417), "Mute button shows: Unmuted", fill=(255, 255, 255), font=font(20))
    d.rounded_rectangle([450, 400, 860, 460], 10, fill=(190, 70, 70))
    d.text((480, 417), "Should show: Muted", fill=(255, 255, 255), font=font(20))
    return "bug-screenshot.png", encode(img)


def pic_palette():
    w, h = 900, 360
    img = Image.new("RGB", (w, h), (246, 246, 249))
    d = ImageDraw.Draw(img)
    cols = [(0.60, 0.70, 0.95), (0.62, 0.50, 0.75), (0.55, 0.25, 0.97), (0.10, 0.60, 0.97), (0.95, 0.55, 0.90), (0.0, 0.0, 0.18)]
    for i, (hh, ss, vv) in enumerate(cols):
        x = 30 + i * 140
        c = rgb(hh, ss, vv)
        d.rounded_rectangle([x, 40, x + 124, 250], 12, fill=c)
        d.text((x + 8, 266), "#%02x%02x%02x" % c, fill=(40, 42, 54), font=font(17))
    d.text((30, 310), "Yap accent palette v2", fill=(40, 42, 54), font=font(20))
    return "palette.png", encode(img)


IMAGES = {
    "sunset": pic_sunset, "mountain": pic_mountain, "beach": pic_beach,
    "dashboard": pic_dashboard, "mockup": pic_mockup, "palette": pic_palette,
}


def avatar(label, hue, size=256):
    img = Image.new("RGB", (size, size), rgb(hue, 0.55, 0.78))
    d = ImageDraw.Draw(img)
    d.ellipse([size * 0.55, -size * 0.2, size * 1.3, size * 0.55], fill=rgb(hue, 0.45, 0.88))
    f = font(int(size * (0.5 if len(label) == 1 else 0.38)))
    box = d.textbbox((0, 0), label, font=f)
    d.text(((size - box[2] - box[0]) / 2, (size - box[3] - box[1]) / 2), label, fill=(255, 255, 255), font=f)
    return encode(img, "JPEG")


# ----------------------------------------------------------------------------
# Talking to the server.


class Api:
    """The bot API (docs/API.md), used as ordinary accounts and as bots."""

    def __init__(self, base):
        self.base = base
        self.tokens = {}

    def login(self, user, password=PASSWORD):
        r = self.call(None, "POST", "/login", {"username": user, "password": password, "device": "demo script"})
        self.tokens[user] = r["token"]

    def call(self, who, method, path, body=None, raw=None, query="", soft=False):
        url = self.base + "/api/v1" + path + query
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        for _ in range(20):
            req = urllib.request.Request(url, data=data, method=method)
            if who is not None:
                req.add_header("Authorization", "Bot " + self.tokens[who])
            if body is not None:
                req.add_header("Content-Type", "application/json")
            try:
                with urllib.request.urlopen(req, timeout=30) as resp:
                    text = resp.read()
                    return json.loads(text) if text else None
            except urllib.error.HTTPError as e:
                text = e.read().decode(errors="replace")
                if e.code == 429:
                    time.sleep(float(e.headers.get("Retry-After", "1")))
                    continue
                if soft:
                    print(f"  ! {method} {path} as {who}: {e.code} {text}", file=sys.stderr)
                    return None
                raise SystemExit(f"{method} {path} as {who}: {e.code} {text}")
        raise SystemExit(f"{method} {path}: rate limited")


class Headless:
    """A bin/yap -headless process whose log is read and which is given commands."""

    def __init__(self, yap, name, server, user, password, keys, logs, extra=()):
        self.name = name
        args = [
            yap, "-headless", server, f"-user:{user}", f"-user-password:{password}",
            f"-key:{keys}/{name}.key", f"-known-servers:{keys}/{name}.known", f"-device:demo", *extra,
        ]
        self.log = open(f"{logs}/{name}.log", "w")
        self.lines = []
        self.cv = threading.Condition()
        self.p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        for line in self.p.stdout:
            self.log.write(line)
            self.log.flush()
            with self.cv:
                self.lines.append(line.rstrip())
                self.cv.notify_all()

    def wait(self, pattern, since=0, timeout=20):
        """The first line from `since` on that matches, as a regex match."""
        end = time.time() + timeout
        with self.cv:
            while True:
                for i in range(since, len(self.lines)):
                    m = re.search(pattern, self.lines[i])
                    if m:
                        return m
                left = end - time.time()
                if left <= 0:
                    return None
                self.cv.wait(left)

    def send(self, line, expect=None, timeout=10):
        """Sends a command, waits for `expect` in the log if given, and
        complains about the warnings and errors it caused."""
        with self.cv:
            since = len(self.lines)
        self.p.stdin.write(line + "\n")
        self.p.stdin.flush()
        m = self.wait(expect, since, timeout) if expect else None
        if expect and not m:
            print(f"  ! {self.name}: no '{expect}' after {line.split()[0]}", file=sys.stderr)
        time.sleep(0.25)
        with self.cv:
            for l in self.lines[since:]:
                if (" WARN " in l or " ERROR " in l) and "has to be changed" not in l:
                    print(f"  ! {self.name}: {line.split(' ')[0]}: {l.split(' ', 3)[-1]}", file=sys.stderr)
        return m

    def ready(self):
        return self.wait(r"looking at|logged in to", 0, 30) is not None

    def stop(self):
        try:
            self.p.stdin.close()
        except OSError:
            pass
        self.p.terminate()
        try:
            self.p.wait(5)
        except subprocess.TimeoutExpired:
            self.p.kill()


def start_server(a, cfg):
    log = open(f"{a.dir}/server.log", "a")
    p = subprocess.Popen([a.server_bin, cfg], stdout=log, stderr=subprocess.STDOUT, cwd=a.dir)
    api = Api(f"http://127.0.0.1:{a.relay_port}")
    for _ in range(100):
        try:
            urllib.request.urlopen(api.base + "/api/v1/server", timeout=1).read()
            return p
        except (urllib.error.URLError, OSError):
            if p.poll() is not None:
                break
            time.sleep(0.1)
    sys.exit(f"the server did not start, see {a.dir}/server.log")


def stop_process(p):
    if p.poll() is None:
        p.terminate()
        try:
            p.wait(10)
        except subprocess.TimeoutExpired:
            p.kill()


# ----------------------------------------------------------------------------
# Making the server.


def write_config(a):
    web = os.path.join(ROOT, "web", "out")
    cfg = {
        "name": SERVER_NAME,
        "port": a.port,
        "data_dir": "data",
        "log_level": "info",
        "relay": {"enabled": True, "port": a.relay_port, "web_dir": web if os.path.isdir(web) else "", "allow_sites": ["*"]},
        "api": {"enabled": True},
        "attachments": {"max_megabytes": 100, "rate_kb": 0, "daily_megabytes": 4096},
    }
    path = os.path.join(a.dir, "config.json")
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
    return path


def seed(a, cfg):
    random.seed(7)
    for d in ("data", "keys", "logs"):
        os.makedirs(os.path.join(a.dir, d), exist_ok=True)
    keys, logs = f"{a.dir}/keys", f"{a.dir}/logs"

    print("making the owner account")
    out = subprocess.run([a.server_bin, "account", "add", "admin", cfg], capture_output=True, text=True, cwd=a.dir)
    m = re.search(r"password: (\S+)", out.stdout + out.stderr)
    if not m:
        sys.exit("could not make the admin account:\n" + out.stdout + out.stderr)
    first_password = m.group(1)
    subprocess.run([a.server_bin, "account", "owner", "admin", cfg], capture_output=True, cwd=a.dir, check=True)

    server = start_server(a, cfg)
    adm = None
    try:
        adm = Headless(a.yap_bin, "admin", f"127.0.0.1:{a.port}", "admin", first_password, keys, logs)
        if not adm.ready():
            sys.exit(f"the admin client could not log in, see {logs}/admin.log")
        adm.send(f"/passwd {first_password} {PASSWORD}", r"password changed|Password changed|changed", 5)
        adm.send(f"/name {ADMIN[1]}")

        print("making accounts, bots and roles")
        for user, display, *_ in PEOPLE:
            adm.send(f"/adduser {user} {PASSWORD} {display}", r"created|Account", 5)
        tokens = {}
        for user, display, _ in BOTS:
            m = adm.send(f"/addbot {user} {display}", r"token for account \d+.*?(yap_\S+)", 10)
            tokens[user] = m.group(1) if m else sys.exit(f"no token for bot {user}")
        for role, (perms, members) in ROLES.items():
            adm.send(f"/mkrole {role} {perms}", r"role|Role", 5)
        for user in sorted({u for _, ms in ROLES.values() for u in ms}):
            adm.send(f"/assign {user} {','.join(r for r, (_, ms) in ROLES.items() if user in ms)}")

        api = Api(f"http://127.0.0.1:{a.relay_port}")
        for user in ["admin"] + [p[0] for p in PEOPLE]:
            api.login(user)
        api.tokens.update(tokens)
        ids = {acc["username"]: acc["id"] for acc in api.call("admin", "GET", "/accounts")}

        print("making channels")
        for name, topic, kind, members, _ in CHANNELS:
            if kind == "private":
                adm.send(f"/private {name}", r"created|subscribed", 5)
            elif name != "Lobby":
                adm.send(f"/create {name}", r"created|subscribed", 5)
            adm.send(f"/view {name}")
            adm.send(f"/topic {topic}")
            if kind == "text-only":
                adm.send("/textonly on")
                adm.send("/rights everyone=see,react Moderators=see,write,react,attach,edit,delete")
            if kind == "private":
                for user in members:
                    if user != "admin":
                        adm.send(f"/invite {user}")
        convs = {c["name"]: c["id"] for c in api.call("admin", "GET", "/convs") if c["kind"] == "channel"}

        # Joining public channels. Everyone is in the home channel already.
        for name, topic, kind, members, _ in CHANNELS:
            if kind == "private" or name == "Lobby":
                continue
            for user in [p[0] for p in PEOPLE] if members == "everyone" else members:
                if user != "admin":
                    api.call(user, "PUT", f"/convs/{convs[name]}/subscription")
        for user, names in SUBSCRIBERS.items():
            for name in names:
                if name != "Lobby":
                    api.call(user, "PUT", f"/convs/{convs[name]}/subscription")
        adm.send("/view Lobby")

        print("profiles")
        for user, display, hue, status, activity, _ in PEOPLE:
            api.call(user, "PUT", "/me/avatar", raw=avatar(display[0], hue))
            if status:
                api.call(user, "PATCH", "/me", {"status": status})
        api.call("admin", "PUT", "/me/avatar", raw=avatar("A", ADMIN[2]))
        for user, display, hue in BOTS:
            api.call(user, "PUT", "/me/avatar", raw=avatar(display[0], hue))
        personas = {}
        for key, (name, label, hue) in {
            "gh": ("GitHub", "GH", 0.66), "deploy": ("Deploy Bot", "D", 0.08),
        }.items():
            personas[name] = api.call("ci", "POST", "/avatars", raw=avatar(label, hue))["id"]

        print("messages")
        uploads = {}

        def upload(who, name, data):
            return api.call(who, "POST", "/uploads", raw=data, query="?name=" + urllib.request.quote(name))["id"]

        def post(conv, m, thread=None):
            body = {"content": mentions(shortcodes(m["text"]), ids)}
            if thread:
                body["thread"] = thread
            if m["persona"]:
                body["persona"] = {"name": m["persona"][0], "avatar": personas[m["persona"][0]]}
            atts = []
            if m["img"]:
                name, data = IMAGES[m["img"]]()
                atts.append(upload(m["who"], name, data))
            if m["file"]:
                name, text = FILES[m["file"]]
                atts.append(upload(m["who"], name, text.encode()))
            if atts:
                body["attachments"] = atts
            msg = api.call(m["who"], "POST", f"/convs/{conv}/messages", body)
            for emoji, users in m["react"].items():
                for u in users:
                    # A reaction is one character of the server's table: no variation selector.
                    api.call(u, "PUT", f"/messages/{msg['id']}/reactions/{urllib.request.quote(emoji.replace(chr(0xfe0f), ''))}", soft=True)
            if m["pin"]:
                api.call("admin", "PUT", f"/messages/{msg['id']}/pin")
            for r in m["replies"]:
                post(conv, r, msg["id"])
            return msg

        for name, *_ in CHANNELS:
            for m in CHAT.get(name, []):
                post(convs[name], m)
        for (x, y), chat in DM_CHAT.items():
            dm = api.call(x, "POST", "/dms", {"account": ids[y]})["id"]
            for m in chat:
                post(dm, m)
        for (conv_name, old), new in EDITS.items():
            for msg in api.call("admin", "GET", f"/convs/{convs[conv_name]}/messages", query="?limit=50"):
                if msg["content"] == old:
                    api.call(msg["author"]["username"], "PATCH", f"/messages/{msg['id']}", {"content": new})
        # The archive happens last, since nobody can post in it.
        for name, topic, kind, *_ in CHANNELS:
            if kind == "archived":
                adm.send(f"/view {name}")
                adm.send("/archive")
        adm.send("/view Lobby")

        # The owner has read everything; the test user, and others, haven't.
        for c in api.call("admin", "GET", "/convs"):
            api.call("admin", "POST", f"/convs/{c['id']}/read", {})
        with open(os.path.join(a.dir, "bots.json"), "w") as f:
            json.dump(tokens, f, indent=2)
    finally:
        if adm:
            adm.stop()
        time.sleep(1)
        stop_process(server)
    backdate(a)


def backdate(a):
    """Spreads the messages out over days, in sessions of people talking, so
    that the chat reads like some days of use. The server isn't running."""
    r = random.Random(3)
    now = int(time.time() * 1000)
    con = sqlite3.connect(os.path.join(a.dir, "data", "yap.db"))
    cur = con.cursor()
    profile = {name: span for name, _, _, _, span in CHANNELS}
    names = {row[0]: row[1] for row in cur.execute("SELECT id, name FROM convs")}
    dm_spans = {}
    for (x, y), span in DMS.items():
        ids = [row[0] for row in cur.execute("SELECT id FROM accounts WHERE username IN (?, ?)", (x, y))]
        a_, b_ = sorted(ids)
        row = cur.execute("SELECT id FROM convs WHERE kind = 1 AND a = ? AND b = ?", (a_, b_)).fetchone()
        if row:
            dm_spans[row[0]] = span
    new_time = {}
    for conv in [row[0] for row in cur.execute("SELECT id FROM convs").fetchall()]:
        msgs = [row[0] for row in cur.execute("SELECT id FROM messages WHERE conv = ? ORDER BY id", (conv,))]
        if not msgs:
            continue
        days, last_ago = profile.get(names.get(conv), dm_spans.get(conv, (3, 60)))
        n = len(msgs)
        sessions = max(1, round(n / 7))
        per = [n // sessions + (1 if i < n % sessions else 0) for i in range(sessions)]
        mean_sep = max(days * 86400 / sessions, 1800)
        end = now - last_ago * 60_000
        times = []
        for s in reversed(range(sessions)):
            span = (per[s] - 1) * r.uniform(40, 150) * 1000
            start = end - span
            session = [start + (span * i / max(per[s] - 1, 1)) * r.uniform(0.9, 1.0) for i in range(per[s])]
            session.sort()
            times = [int(t) for t in session] + times
            end = start - r.uniform(0.5, 1.5) * mean_sep * 1000
        for mid, t in zip(msgs, sorted(times)):
            new_time[mid] = t
            cur.execute("UPDATE messages SET time = ? WHERE id = ?", (t, mid))
        cur.execute("UPDATE convs SET created = ? WHERE id = ?", (min(times) - 3_600_000 * 5, conv))
    for mid, t in new_time.items():
        cur.execute("UPDATE reactions SET time = ? WHERE message = ?", (t + r.randint(20, 900) * 1000, mid))
    for mid in [row[0] for row in cur.execute("SELECT message FROM pins").fetchall()]:
        cur.execute("UPDATE pins SET time = ? WHERE message = ?", (new_time.get(mid, now) + 60_000, mid))
    day = 86_400_000
    cur.execute("UPDATE accounts SET created = ?, flags = flags & ?", (now - 21 * day, ~MUST_CHANGE & 0xFF))
    for user, hours in (("grace", 3), ("heidi", 50)):
        cur.execute("UPDATE accounts SET last_seen = ? WHERE username = ?", (now - hours * 3_600_000, user))
    con.commit()
    con.close()


# ----------------------------------------------------------------------------
# Running it.


def main():
    sys.stdout.reconfigure(line_buffering=True)
    ap = argparse.ArgumentParser(description="Sets up and runs a demo yap server (see the top of this file).")
    ap.add_argument("--dir", default=os.path.join(ROOT, "demo-server"), help="where the server's files go (default ./demo-server)")
    ap.add_argument("--reset", action="store_true", help="delete the demo server's data and make it again")
    ap.add_argument("--seed-only", action="store_true", help="make the data and stop, without running anything")
    ap.add_argument("--no-clients", action="store_true", help="run only the server, with nobody online")
    ap.add_argument("--no-voice", action="store_true", help="the clients stay out of the voice rooms")
    ap.add_argument("--bin", default=os.path.join(ROOT, "bin"), help="where yap and yap-server are (default ./bin)")
    ap.add_argument("--port", type=int, default=17777, help="the server's UDP port (default 17777; the media link is the next one)")
    ap.add_argument("--relay-port", type=int, default=18080, help="the web relay's and API's TCP port (default 18080)")
    a = ap.parse_args()
    a.dir = os.path.abspath(a.dir)
    exe = ".exe" if os.name == "nt" else ""
    a.yap_bin = os.path.join(a.bin, "yap" + exe)
    a.server_bin = os.path.join(a.bin, "yap-server" + exe)
    for path in (a.yap_bin, a.server_bin):
        if not os.path.exists(path):
            sys.exit(f"{path} is missing, build it with ./build.sh (or pass --bin)")

    if a.reset and os.path.isdir(a.dir):
        if not os.path.exists(os.path.join(a.dir, "config.json")):
            sys.exit(f"{a.dir} doesn't look like a demo server, not deleting it")
        import shutil
        shutil.rmtree(a.dir)
    os.makedirs(a.dir, exist_ok=True)
    cfg = write_config(a)
    if not os.path.exists(os.path.join(a.dir, "data", "yap.db")):
        seed(a, cfg)
        print("done")
    if a.seed_only:
        return

    server = start_server(a, cfg)
    clients = []

    def stop(*_):
        print("\nstopping")
        for c in clients:
            c.stop()
        stop_process(server)
        sys.exit(0)

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    if not a.no_clients:
        keys, logs = f"{a.dir}/keys", f"{a.dir}/logs"
        for user, display, hue, status, wanted, where in PEOPLE:
            if not where:
                continue
            activity, room, tone = where
            extra = [f"-tone:{tone}"] if tone else []
            c = Headless(a.yap_bin, user, f"127.0.0.1:{a.port}", user, PASSWORD, keys, logs, extra)
            clients.append(c)
            if not c.ready():
                print(f"  ! {user} did not log in, see {logs}/{user}.log", file=sys.stderr)
                continue
            c.send(f"/activity {activity}")
            if room and not a.no_voice:
                c.send(f"/join {room}")
                if not tone:
                    c.send("/mute")
    online = [p[0] for p in PEOPLE if p[5]]
    print(f"""
Demo server is up.

  server      127.0.0.1:{a.port}   (UDP; the media link is {a.port + 1})
  web client  http://127.0.0.1:{a.relay_port}/  (if web/out is built)
  bot API     http://127.0.0.1:{a.relay_port}/api/v1/

  log in as   admin / {PASSWORD}   the owner
              demo  / {PASSWORD}   an ordinary member (has unread messages and a mention)
  online      {', '.join(online) if not a.no_clients else 'nobody'}
              (all accounts use {PASSWORD}; grace and heidi are offline)
  bots        weather, ci, dice (tokens in {a.dir}/bots.json)

Ctrl+C stops it. Logs are in {a.dir}/server.log and {a.dir}/logs/.""")
    while True:
        time.sleep(1)
        if server.poll() is not None:
            print(f"the server stopped, see {a.dir}/server.log", file=sys.stderr)
            stop()


if __name__ == "__main__":
    main()
