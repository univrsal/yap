#!/usr/bin/env python3
"""
Makes a yap-server data directory full of made-up history, for seeing
how the server and clients hold up with years of messages: about what
moving a team's chat over from another system (Mattermost, say) would
bring along.

	scripts/gen_testdata.py <data_dir> [options]

<data_dir> gets what a server keeps there: yap.db and blobs/. Point a
config's "data_dir" at it and start the server as usual.

What's made, by default (see --help for the knobs):

  - USERS accounts (30): `admin` owns the server, the others are user01,
    user02, ... All have the password PASSWORD ("password"), hashed with
    the server's test parameters (argon2id set 0) so making them is
    instant; logging in works as with any other. A few have the
    `moderators` role.
  - channels: the home channel everyone is in, public ones with most
    people, a few private ones, one archived; and DMs between people
    who talk to each other. Some people talk much more than others,
    and so do some channels.
  - messages, until yap.db is DB_SIZE (3 GB): spread over YEARS years
    up to now, in bursts of a few people talking, with threads,
    mentions, reactions, edits, deletions, forwards, pins, file offers
    in DMs, and pictures: one message in IMAGE_EVERY is one, a message
    with no text carrying the picture as its one file, the way a pasted
    one is sent. Each picture is a JPEG of the kind the client makes of
    a paste (at most 3840 pixels a side and 256 KB), in blobs/ like the
    server keeps them; a few are posted twice, so they're stored once.
  - who has read how far, buddies.

The pictures are made from a pool of POOL drawings (screenshots,
photos, small ones), each copy made a different file by a comment of
its own in the JPEG: the server and clients see that many different
pictures, of realistic sizes, for a fraction of the time it would take
to draw each.

The schema is the server's own: the steps in src/server/db_schema.odin
are read from there and run, so a database made here is the one the
server would have made, at the version it knows.

It takes a while: some minutes per GB of database, and the pictures are
written at the disk's speed. Same --seed, same data.

Needs Python 3 with Pillow (for the pictures).
"""

import argparse
import hashlib
import io
import math
import multiprocessing
import os
import random
import re
import sqlite3
import struct
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMA_FILE = os.path.join(ROOT, "src/server/db_schema.odin")

# The server's names and numbers (src/common/proto, src/server).
DB_FILE = "yap.db"
BLOBS_DIR = "blobs"

MSG_TEXT, MSG_FILE = 0, 2
FLAG_DELETED, FLAG_PINNED, FLAG_HAS_THREAD, FLAG_FORWARDED = 1, 2, 4, 8
FLAG_HAS_ATTACHMENTS = 16
CONV_CHANNEL, CONV_DM = 0, 1
CONV_HOME, CONV_PRIVATE, CONV_ARCHIVED = 1, 2, 4
ACCOUNT_OWNER = 1
BLOB_FILE = 4
MAX_CHAT_SIZE = 500
MAX_IMAGE_SIZE = 256 * 1024  # what the client makes of a paste (src/client/image.odin)
MAX_IMAGE_SIDE = 3840
MAX_PINS = 50
PERM_MANAGE_MESSAGES, PERM_PIN_MESSAGES = 4, 5

# The password hash: argon2id with the server's parameter set 0
# (src/server/hash_worker.odin), 32 bytes of hash, 16 of salt.
HASH_PARAMS_TEST = 0
ARGON2_TEST = dict(memory_kib=8, passes=1, lanes=1)
HASH_SIZE = 32
SALT_SIZE = 16


# ---------------------------------------------------------------------------
# argon2id (RFC 9106), as plain Python: slow, but the test parameters
# make it 8 blocks.

M64 = (1 << 64) - 1


def _blake2b_long(data, size):
    pre = struct.pack("<I", size)
    if size <= 64:
        return hashlib.blake2b(pre + data, digest_size=size).digest()
    out = bytearray()
    v = hashlib.blake2b(pre + data, digest_size=64).digest()
    out += v[:32]
    while size - len(out) > 64:
        v = hashlib.blake2b(v, digest_size=64).digest()
        out += v[:32]
    out += hashlib.blake2b(v, digest_size=size - len(out)).digest()
    return bytes(out)


def _rotr(x, n):
    return ((x >> n) | (x << (64 - n))) & M64


def _gb(v, a, b, c, d):
    va, vb, vc, vd = v[a], v[b], v[c], v[d]
    va = (va + vb + 2 * (va & 0xFFFFFFFF) * (vb & 0xFFFFFFFF)) & M64
    vd = _rotr(vd ^ va, 32)
    vc = (vc + vd + 2 * (vc & 0xFFFFFFFF) * (vd & 0xFFFFFFFF)) & M64
    vb = _rotr(vb ^ vc, 24)
    va = (va + vb + 2 * (va & 0xFFFFFFFF) * (vb & 0xFFFFFFFF)) & M64
    vd = _rotr(vd ^ va, 16)
    vc = (vc + vd + 2 * (vc & 0xFFFFFFFF) * (vd & 0xFFFFFFFF)) & M64
    vb = _rotr(vb ^ vc, 63)
    v[a], v[b], v[c], v[d] = va, vb, vc, vd


def _permute(v, idx):
    # idx: the 16 words of one row or column, in order.
    w = [v[i] for i in idx]
    _gb(w, 0, 4, 8, 12)
    _gb(w, 1, 5, 9, 13)
    _gb(w, 2, 6, 10, 14)
    _gb(w, 3, 7, 11, 15)
    _gb(w, 0, 5, 10, 15)
    _gb(w, 1, 6, 11, 12)
    _gb(w, 2, 7, 8, 13)
    _gb(w, 3, 4, 9, 14)
    for i, x in zip(idx, w):
        v[i] = x


_ROWS = [list(range(16 * i, 16 * i + 16)) for i in range(8)]
_COLS = [[2 * i + 16 * j + k for j in range(8) for k in (0, 1)] for i in range(8)]


def _fill_block(prev, ref, cur, with_xor):
    r = [a ^ b for a, b in zip(prev, ref)]
    tmp = [a ^ b for a, b in zip(r, cur)] if with_xor else list(r)
    for idx in _ROWS:
        _permute(r, idx)
    for idx in _COLS:
        _permute(r, idx)
    return [a ^ b for a, b in zip(tmp, r)]


def _block_of(data):
    return list(struct.unpack("<128Q", data))


def argon2id(password, salt, memory_kib, passes, lanes, size):
    h0 = hashlib.blake2b(
        struct.pack("<6I", lanes, size, memory_kib, passes, 0x13, 2)
        + struct.pack("<I", len(password)) + password
        + struct.pack("<I", len(salt)) + salt
        + struct.pack("<I", 0) + struct.pack("<I", 0),
        digest_size=64,
    ).digest()
    blocks = 4 * lanes * (memory_kib // (4 * lanes))
    lane_len = blocks // lanes
    seg_len = lane_len // 4
    mem = [None] * blocks
    for l in range(lanes):
        for i in (0, 1):
            mem[l * lane_len + i] = _block_of(_blake2b_long(h0 + struct.pack("<II", i, l), 1024))
    zero = [0] * 128
    for p in range(passes):
        for s in range(4):
            for l in range(lanes):
                independent = p == 0 and s < 2
                inp = addr = None
                if independent:
                    inp = [0] * 128
                    inp[0:6] = [p, l, s, blocks, passes, 2]

                    def next_addresses():
                        inp[6] += 1
                        a = _fill_block(zero, inp, zero, False)
                        return _fill_block(zero, a, zero, False)

                start = 0
                if p == 0 and s == 0:
                    start = 2
                    if independent:
                        addr = next_addresses()
                cur = l * lane_len + s * seg_len + start
                prev = cur + lane_len - 1 if cur % lane_len == 0 else cur - 1
                for i in range(start, seg_len):
                    if cur % lane_len == 1:
                        prev = cur - 1
                    if independent:
                        if i % 128 == 0:
                            addr = next_addresses()
                        rand = addr[i % 128]
                    else:
                        rand = mem[prev][0]
                    ref_lane = (rand >> 32) % lanes
                    if p == 0 and s == 0:
                        ref_lane = l
                    same = ref_lane == l
                    if p == 0:
                        if s == 0:
                            area = i - 1
                        elif same:
                            area = s * seg_len + i - 1
                        else:
                            area = s * seg_len + (-1 if i == 0 else 0)
                    else:
                        if same:
                            area = lane_len - seg_len + i - 1
                        else:
                            area = lane_len - seg_len + (-1 if i == 0 else 0)
                    rel = rand & 0xFFFFFFFF
                    rel = (rel * rel) >> 32
                    rel = area - 1 - ((area * rel) >> 32)
                    begin = 0 if p == 0 or s == 3 else (s + 1) * seg_len
                    ref = ref_lane * lane_len + (begin + rel) % lane_len
                    mem[cur] = _fill_block(mem[prev], mem[ref], mem[cur] or zero, p != 0)
                    cur += 1
                    prev += 1
    last = list(mem[lane_len - 1])
    for l in range(1, lanes):
        last = [a ^ b for a, b in zip(last, mem[l * lane_len + lane_len - 1])]
    return _blake2b_long(struct.pack("<128Q", *last), size)


def password_secret(password, rng):
    salt = rng.randbytes(SALT_SIZE)
    h = argon2id(password.encode(), salt, size=HASH_SIZE, **ARGON2_TEST)
    return h, salt, HASH_PARAMS_TEST


# ---------------------------------------------------------------------------
# The schema, from the server's source.


def read_migrations():
    with open(SCHEMA_FILE, encoding="utf-8") as f:
        src = f.read()
    m = re.search(r"MIGRATIONS := \[\?\]string \{(.*?)\n\}", src, re.S)
    if not m:
        sys.exit(f"{SCHEMA_FILE}: no MIGRATIONS found")
    # The comments between the steps quote names in backticks too.
    body = "\n".join(line for line in m.group(1).split("\n") if not line.lstrip().startswith("//"))
    steps = re.findall(r"`(.*?)`", body, re.S)
    if not steps:
        sys.exit(f"{SCHEMA_FILE}: MIGRATIONS has no steps")
    return steps


def create_schema(db):
    # As db_open does for a new database: freed pages can go back to the
    # filesystem only if asked for before the first table.
    db.execute("PRAGMA auto_vacuum = INCREMENTAL")
    steps = read_migrations()
    for step in steps:
        db.executescript(step)
    db.execute(f"PRAGMA user_version = {len(steps)}")
    db.commit()
    return len(steps)


# ---------------------------------------------------------------------------
# Words.

COMMON = """
the be to of and a in that have i it for not on with he as you do at this but
his by from they we say her she or an will my one all would there their what so
up out if about who get which go me when make can like time no just him know
take people into year your good some could them see other than then now look
only come its over think also back after use two how our work first well way
even new want because any these give day most us is was are been has had were
yes ok okay yeah lol haha thanks thx please sure maybe tomorrow today tonight
later soon morning meeting lunch coffee build test fix bug issue merge branch
commit push deploy server client release version update patch config error
log crash works broken weird problem question idea plan doc docs review link
file image screenshot video call voice mic audio sound headset stream screen
game play match round win lose team map server lag ping fps update patch mod
code function api database query index table cache memory cpu disk network
port socket packet latency timeout retry install linux windows mac build
compile linker warning debug trace profile benchmark slow fast faster quick
right wrong agree nice cool great awesome perfect exactly true probably
actually really still already again never always sometimes often just
here there where why how what when who which whose whom something nothing
anything everything someone anyone everyone nobody week month weekend friday
monday tuesday wednesday thursday saturday sunday hour minute second minutes
hours days weeks home office remote online offline away busy back afk brb gg
""".split()

SYLLABLES = """
ba be bi bo bu da de di do du fa fe fi fo ga ge go ka ke ki ko ku la le li lo
lu ma me mi mo mu na ne ni no nu pa pe pi po ra re ri ro ru sa se si so su ta
te ti to tu va ve vi vo za ze zi zo an en in on er ar or ux ix ex ul il ol ent
ast ost ism ing ter ver str sch tr pl kr gr bl
""".split()

EMOJI = list("😀😂🙂😉😍🤔😅😭😎🙄👍👎👌🙏👀🔥🎉💯❤🚀✅❌⚠🐛☕🍕")
TLDS = ["com", "org", "net", "io", "dev", "de"]


class Words:
    """A vocabulary with a long tail, drawn from Zipf-like: the common
    words most of the time, made-up ones (names, jargon, typos) now and
    then, as a full-text index sees in a real chat."""

    def __init__(self, rng, rare=30000):
        made = set()
        while len(made) < rare:
            made.add("".join(rng.choice(SYLLABLES) for _ in range(rng.randint(2, 4))))
        self.words = COMMON + sorted(made)
        rng.shuffle(self.words[len(COMMON):])
        acc = 0.0
        self.cum = []
        for i in range(len(self.words)):
            acc += 1.0 / (i + 1) ** 1.05
            self.cum.append(acc)

    def take(self, rng, n):
        return rng.choices(self.words, cum_weights=self.cum, k=n)


def fit_text(text):
    data = text.encode()
    if len(data) <= MAX_CHAT_SIZE:
        return text
    return data[:MAX_CHAT_SIZE].decode(errors="ignore").rstrip()


# ---------------------------------------------------------------------------
# Pictures.


def draw_picture(args):
    """One drawing of the pool, as the client would send it: a JPEG of at
    most MAX_IMAGE_SIDE a side, its quality lowered until it's at most
    MAX_IMAGE_SIZE. Runs in a worker process."""
    from PIL import Image, ImageDraw, ImageFilter

    seed, kind = args
    rng = random.Random(seed)
    if kind == "screenshot":
        w, h = rng.choice([(1920, 1080), (2560, 1440), (1366, 768), (1280, 720), (3840, 2160)])
        img = Image.new("RGB", (w, h), tuple(rng.randrange(256) for _ in range(3)))
        d = ImageDraw.Draw(img)
        for _ in range(rng.randint(20, 80)):
            x, y = rng.randrange(w), rng.randrange(h)
            d.rectangle(
                [x, y, x + rng.randint(40, w // 2), y + rng.randint(20, h // 3)],
                fill=tuple(rng.randrange(256) for _ in range(3)),
            )
        for _ in range(rng.randint(40, 400)):
            x, y = rng.randrange(w), rng.randrange(h)
            d.text((x, y), "".join(rng.choice("abcdefghij klmnopqrstuvwxyz0123456789") for _ in range(rng.randint(5, 60))), fill=(0, 0, 0))
    else:
        if kind == "photo":
            w, h = rng.choice([(4032, 3024), (3840, 2160), (3000, 2000), (2048, 1536), (1600, 1200)])
            if rng.random() < 0.3:
                w, h = h, w
        else:  # small: memes, stickers, crops
            w, h = rng.choice([(480, 480), (640, 480), (800, 600), (500, 700), (1024, 768)])
        # Something photo-like: smooth shapes, blurred, with grain, which
        # JPEG has to work for.
        sw, sh = max(1, w // 8), max(1, h // 8)
        img = Image.new("RGB", (sw, sh), tuple(rng.randrange(256) for _ in range(3)))
        d = ImageDraw.Draw(img)
        for _ in range(rng.randint(15, 60)):
            x, y = rng.randrange(sw), rng.randrange(sh)
            r = rng.randint(2, max(3, sw // 3))
            d.ellipse([x - r, y - r, x + r, y + r], fill=tuple(rng.randrange(256) for _ in range(3)))
        img = img.filter(ImageFilter.GaussianBlur(rng.uniform(1, 4))).resize((w, h), Image.BILINEAR)
        noise = Image.effect_noise((w, h), rng.uniform(10, 40)).convert("RGB")
        img = Image.blend(img, noise, rng.uniform(0.05, 0.25))
    scale = MAX_IMAGE_SIDE / max(img.size)
    if scale < 1:
        img = img.resize((int(img.width * scale), int(img.height * scale)), Image.BILINEAR)
    for quality in range(90, 4, -5):
        out = io.BytesIO()
        img.save(out, "JPEG", quality=quality)
        data = out.getvalue()
        if len(data) <= MAX_IMAGE_SIZE - 64:  # room for the comment
            return data, img.width, img.height
    # Still too big: smaller, as the client would end up doing.
    img = img.resize((img.width // 2, img.height // 2), Image.BILINEAR)
    out = io.BytesIO()
    img.save(out, "JPEG", quality=50)
    return out.getvalue(), img.width, img.height


def make_pool(count, seed, jobs):
    kinds = []
    rng = random.Random(seed)
    for i in range(count):
        r = rng.random()
        kinds.append((seed * 1000003 + i, "screenshot" if r < 0.45 else "photo" if r < 0.85 else "small"))
    with multiprocessing.Pool(jobs) as pool:
        return pool.map(draw_picture, kinds, chunksize=1)


def unique_copy(jpeg, tag):
    """The same picture as a different file: a JPEG comment (COM) right
    after the start marker."""
    payload = b"yap testdata " + tag
    return jpeg[:2] + b"\xff\xfe" + struct.pack(">H", len(payload) + 2) + payload + jpeg[2:]


class Blobs:
    def __init__(self, db, data_dir):
        self.db = db
        self.dir = os.path.join(data_dir, BLOBS_DIR)
        os.makedirs(self.dir, exist_ok=True)
        self.next_id = 1
        self.rows = []
        self.bytes = 0
        self.count = 0

    def put(self, data, width, height, created, by):
        sha = hashlib.sha256(data).digest()
        name = sha.hex()
        folder = os.path.join(self.dir, name[:2])
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, name)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        bid = self.next_id
        self.next_id += 1
        self.rows.append((bid, sha, len(data), BLOB_FILE, width, height, created, by))
        self.bytes += len(data)
        self.count += 1
        return bid

    def flush(self):
        self.db.executemany(
            "INSERT INTO blobs (id, sha256, size, kind, width, height, created, by) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            self.rows,
        )
        self.rows.clear()


# ---------------------------------------------------------------------------
# People and conversations.

CHANNEL_NAMES = [
    "Lobby", "Gaming", "general", "random", "dev", "backend", "frontend", "ops",
    "releases", "bugs", "design", "music", "movies", "food", "memes", "hardware",
    "linux", "help", "announcements", "offtopic", "books", "travel", "sports",
    "server-admin", "ideas",
]
PRIVATE_NAMES = ["mods", "planning", "secret-santa", "hiring"]
ARCHIVED_NAMES = ["old-project"]

FILE_NAMES = ["notes.txt", "build.log", "report.pdf", "photos.zip", "slides.pptx",
              "dump.sql", "config.json", "song.flac", "video.mkv", "patch.diff"]


class Conv:
    __slots__ = ("id", "kind", "members", "weight", "last", "recent", "roots", "created")

    def __init__(self, cid, kind, members, weight, created):
        self.id = cid
        self.kind = kind
        self.members = members
        self.weight = weight
        self.last = 0
        self.recent = []  # recent message ids, for read marks
        self.roots = []  # recent top-level messages, for threads
        self.created = created


def zipf_weights(n, s, rng):
    w = [1.0 / (i + 1) ** s for i in range(n)]
    rng.shuffle(w)
    return w


def make_people(db, args, rng, start_ms):
    secrets = password_secret(args.password, rng)
    accounts = []
    names = ["admin"] + [f"user{i:02d}" for i in range(1, args.users)]
    for i, name in enumerate(names):
        aid = i + 1
        # One hash for all: each would take as long and be as good.
        h, salt, params = secrets
        display = "Admin" if i == 0 else f"User {i:02d}"
        created = start_ms - rng.randint(0, 86_400_000)
        db.execute(
            "INSERT INTO accounts (id, username, display, pw_hash, pw_salt, pw_params, flags, created, last_seen) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (aid, name, display, h, salt, params, ACCOUNT_OWNER if i == 0 else 0, created, 0),
        )
        accounts.append(aid)

    db.execute(
        "INSERT INTO roles (name, perms) VALUES ('moderators', ?)",
        ((1 << PERM_MANAGE_MESSAGES) | (1 << PERM_PIN_MESSAGES),),
    )
    mod_role = db.execute("SELECT id FROM roles WHERE name = 'moderators'").fetchone()[0]
    for aid in rng.sample(accounts[1:], min(3, len(accounts) - 1)):
        db.execute("INSERT INTO account_roles (account, role) VALUES (?, ?)", (aid, mod_role))

    for aid in accounts:
        for other in rng.sample(accounts, min(len(accounts), rng.randint(3, 10))):
            if other != aid:
                db.execute("INSERT OR IGNORE INTO buddies (account, buddy) VALUES (?, ?)", (aid, other))
    return accounts


def make_convs(db, args, rng, accounts, start_ms):
    convs = []
    cid = 0

    def channel(name, flags, members, weight, position):
        nonlocal cid
        cid += 1
        created = start_ms + (0 if flags & CONV_HOME else rng.randint(0, 30 * 86_400_000))
        db.execute(
            "INSERT INTO convs (id, kind, flags, name, topic, position, created, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (cid, CONV_CHANNEL, flags, name, f"All about {name}" if rng.random() < 0.6 else "", position, created,
             None if flags & CONV_HOME else rng.choice(accounts)),
        )
        conv = Conv(cid, CONV_CHANNEL, sorted(members), weight, created)
        convs.append(conv)
        return conv

    n_public = min(args.channels, len(CHANNEL_NAMES))
    weights = zipf_weights(n_public, 0.9, rng)
    for i in range(n_public):
        if i == 0:
            members = accounts
            weights[0] = max(weights)
        else:
            members = rng.sample(accounts, max(2, int(len(accounts) * rng.uniform(0.4, 1.0))))
        channel(CHANNEL_NAMES[i], CONV_HOME if i == 0 else 0, members, weights[i], i)
    for i, name in enumerate(PRIVATE_NAMES):
        members = rng.sample(accounts, min(len(accounts), rng.randint(3, 10)))
        channel(name, CONV_PRIVATE, members, min(weights) * rng.uniform(1, 4), n_public + i)
    for i, name in enumerate(ARCHIVED_NAMES):
        members = rng.sample(accounts, max(2, len(accounts) // 2))
        channel(name, CONV_ARCHIVED, members, min(weights), n_public + len(PRIVATE_NAMES) + i)
    channel_total = sum(c.weight for c in convs)

    # DMs: each person talks to a handful of others, some a lot.
    pairs = set()
    for a in accounts:
        for b in rng.sample(accounts, min(len(accounts), args.dm_partners)):
            if a != b:
                pairs.add((min(a, b), max(a, b)))
    dm_weights = zipf_weights(len(pairs), 1.0, rng)
    scale = channel_total * args.dm_share / (1 - args.dm_share) / sum(dm_weights)
    for (a, b), w in zip(sorted(pairs), dm_weights):
        cid += 1
        created = start_ms + rng.randint(0, 180 * 86_400_000)
        db.execute(
            "INSERT INTO convs (id, kind, a, b, created, created_by) VALUES (?, 1, ?, ?, ?, ?)",
            (cid, a, b, created, rng.choice((a, b))),
        )
        convs.append(Conv(cid, CONV_DM, [a, b], w * scale, created))

    for c in convs:
        db.executemany(
            "INSERT INTO members (conv, account, joined) VALUES (?, ?, ?)",
            [(c.id, a, c.created) for a in c.members],
        )
    return convs


# ---------------------------------------------------------------------------
# Messages.


class Gen:
    def __init__(self, args, db, rng, accounts, convs, pool, blobs):
        self.args = args
        self.db = db
        self.rng = rng
        self.convs = convs
        self.conv_cum = []
        acc = 0.0
        for c in convs:
            acc += c.weight
            self.conv_cum.append(acc)
        self.user_weight = dict(zip(accounts, zipf_weights(len(accounts), 0.8, rng)))
        self.words = Words(rng)
        self.pool = pool
        self.blobs = blobs
        self.posted_blobs = []  # (id, size)
        self.pictures = 0
        self.attachments = []
        self.file_names = []
        self.next_id = 1
        self.msgs = []
        self.mentions = []
        self.reactions = []
        self.threads = {}  # root -> [replies, last reply]
        self.forwardable = []  # (id, conv, sender, time, text)
        self.count = 0
        self.bursts = 0
        self.kinds = [0, 0, 0]
        self.text_bytes = 0

    def text(self, conv, sender):
        rng = self.rng
        n = max(1, min(90, int(rng.lognormvariate(math.log(7), 0.8))))
        words = self.words.take(rng, n)
        mentioned = []
        r = rng.random()
        if r < 0.03:
            words.insert(rng.randrange(len(words) + 1),
                         f"https://{rng.choice(self.words.words[len(COMMON):])}.{rng.choice(TLDS)}/{'/'.join(self.words.take(rng, rng.randint(1, 3)))}")
        elif r < 0.05:
            words.insert(0, rng.choice(EMOJI))
        elif r < 0.06:
            words = ["`" + " ".join(words) + "`"]
        mention_rate = self.args.mention_rate if conv.kind == CONV_CHANNEL else self.args.mention_rate / 4
        if rng.random() < mention_rate:
            others = [m for m in conv.members if m != sender]
            if others:
                if conv.kind == CONV_CHANNEL and sender == 1 and rng.random() < 0.01:
                    words.insert(0, "<@everyone>")
                    mentioned = others
                else:
                    who = rng.choice(others)
                    words.insert(rng.randrange(len(words) + 1), f"<@{who}>")
                    mentioned = [who]
        text = " ".join(words)
        if rng.random() < 0.6:
            text = text[0].upper() + text[1:]
        if rng.random() < 0.3:
            text += rng.choice(".!?")
        return fit_text(text), mentioned

    def post(self, conv, sender, t, thread_root):
        rng = self.rng
        mid = self.next_id
        self.next_id += 1
        kind = MSG_TEXT
        text = None
        flags = 0
        edited = 0
        file_size = 0
        fwd = (0, 0, 0)
        r = rng.random()
        if r < self.args.image_rate:
            # A pasted picture: no text, the picture its one file.
            if self.posted_blobs and rng.random() < 0.02:
                blob, size = rng.choice(self.posted_blobs)  # the same picture again
            else:
                jpeg, w, h = rng.choice(self.pool)
                data = unique_copy(jpeg, str(self.blobs.next_id).encode())
                blob, size = self.blobs.put(data, w, h, t, sender), len(data)
                if len(self.posted_blobs) < 10000:
                    self.posted_blobs.append((blob, size))
                else:
                    self.posted_blobs[rng.randrange(10000)] = (blob, size)
            text = ""
            flags |= FLAG_HAS_ATTACHMENTS
            name = time.strftime("pasted-image-%Y%m%d-%H%M%S.jpg", time.gmtime(t // 1000))
            self.attachments.append((mid, 0, blob, name, size))
            self.file_names.append((mid, name))
            self.pictures += 1
        elif conv.kind == CONV_DM and r < self.args.image_rate + 0.003:
            kind = MSG_FILE
            text = rng.choice(FILE_NAMES)
            file_size = rng.randint(1000, 2_000_000_000)
        elif r < self.args.image_rate + 0.005 and self.forwardable:
            src = rng.choice(self.forwardable)
            text = src[4]
            flags |= FLAG_FORWARDED
            fwd = (src[2], src[1], src[3])  # who wrote it, where, when
        elif rng.random() < 0.005:
            # Deleted: what's left of it, as Msg_Delete leaves it.
            flags |= FLAG_DELETED
        else:
            text, mentioned = self.text(conv, sender)
            for who in mentioned:
                self.mentions.append((who, conv.id, mid))
            if rng.random() < 0.03:
                edited = t + rng.randint(5_000, 600_000)
            if len(self.forwardable) < 2000:
                self.forwardable.append((mid, conv.id, sender, t, text))
            elif rng.random() < 0.01:
                self.forwardable[rng.randrange(2000)] = (mid, conv.id, sender, t, text)
        if text is not None:
            self.text_bytes += len(text.encode())
        self.kinds[kind] += 1

        if not flags & FLAG_DELETED and rng.random() < self.args.reaction_rate:
            for emoji in rng.sample(EMOJI, rng.randint(1, 3)):
                for who in rng.sample(conv.members, rng.randint(1, min(4, len(conv.members)))):
                    self.reactions.append((mid, emoji, who, t + rng.randint(1_000, 3_600_000)))

        nonce = rng.getrandbits(63)
        self.msgs.append((mid, conv.id, sender, t, kind, flags, thread_root, text, edited, nonce,
                          file_size, fwd[0], fwd[1], fwd[2]))
        if thread_root:
            th = self.threads.setdefault(thread_root, [0, 0])
            if not flags & FLAG_DELETED:
                th[0] += 1
                th[1] = mid
        elif not flags & FLAG_DELETED:
            conv.roots.append(mid)
            if len(conv.roots) > 64:
                del conv.roots[:32]
        conv.last = mid
        conv.recent.append(mid)
        if len(conv.recent) > 64:
            del conv.recent[:32]
        self.count += 1

    def burst(self, t, gap_ms):
        """A few people talking in one conversation, maybe in a thread.
        Returns the time after it."""
        rng = self.rng
        conv = self.convs[_bisect(self.conv_cum, rng.random() * self.conv_cum[-1])]
        k = min(len(conv.members), rng.choice((2, 2, 2, 3, 3, 4, 5)))
        talkers = _weighted_sample(rng, conv.members, [self.user_weight[m] for m in conv.members], k)
        thread_root = 0
        thread_chance = self.args.thread_rate if conv.kind == CONV_CHANNEL else self.args.thread_rate / 5
        if conv.roots and rng.random() < thread_chance:
            thread_root = conv.roots[-1 - min(len(conv.roots) - 1, int(rng.expovariate(0.3)))]
        n = 1 + int(rng.expovariate(1 / 5))
        self.bursts += 1
        for _ in range(n):
            self.post(conv, rng.choice(talkers), t, thread_root)
            t += int(rng.expovariate(1 / gap_ms))
        return t

    def flush(self):
        self.blobs.flush()
        self.db.executemany(
            "INSERT INTO messages (id, conv, sender, time, kind, flags, thread_root, text, edited, nonce, file_size, fwd_sender, fwd_conv, fwd_time) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            self.msgs,
        )
        self.db.executemany("INSERT INTO attachments (msg, idx, blob, name, size) VALUES (?, ?, ?, ?, ?)", self.attachments)
        self.db.executemany("INSERT INTO files_fts (rowid, names) VALUES (?, ?)", self.file_names)
        self.db.executemany("INSERT OR IGNORE INTO mentions (account, conv, message) VALUES (?, ?, ?)", self.mentions)
        self.db.executemany("INSERT OR IGNORE INTO reactions (message, emoji, account, time) VALUES (?, ?, ?, ?)", self.reactions)
        self.msgs.clear()
        self.attachments.clear()
        self.file_names.clear()
        self.mentions.clear()
        self.reactions.clear()
        self.db.commit()


def _bisect(cum, x):
    lo, hi = 0, len(cum) - 1
    while lo < hi:
        mid = (lo + hi) // 2
        if cum[mid] < x:
            lo = mid + 1
        else:
            hi = mid
    return lo


def _weighted_sample(rng, items, weights, k):
    items, weights = list(items), list(weights)
    out = []
    for _ in range(k):
        i = _bisect(list(_accumulate(weights)), rng.random() * sum(weights))
        out.append(items.pop(i))
        weights.pop(i)
    return out


def _accumulate(ws):
    acc = 0.0
    for w in ws:
        acc += w
        yield acc


def finish(db, gen, convs, rng, now_ms):
    print("threads, read marks, pins...", flush=True)
    db.executemany(
        "UPDATE messages SET reply_count = ?, last_reply = ?, flags = flags | ? WHERE id = ?",
        [(n, last, FLAG_HAS_THREAD, root) for root, (n, last) in gen.threads.items()],
    )
    for c in convs:
        db.execute("UPDATE convs SET last_msg = ? WHERE id = ?", (c.last, c.id))
        for a in c.members:
            # Most have read everything; some are behind.
            read = c.last
            if c.recent and rng.random() < 0.25:
                read = rng.choice(c.recent)
            db.execute("UPDATE members SET read_id = ? WHERE conv = ? AND account = ?", (read, c.id, a))
        if c.recent:
            pins = rng.sample(c.recent, min(len(c.recent), rng.randint(0, 8), MAX_PINS))
            for mid in pins:
                if db.execute("SELECT flags & ? FROM messages WHERE id = ?", (FLAG_DELETED, mid)).fetchone()[0]:
                    continue
                db.execute("UPDATE messages SET flags = flags | ? WHERE id = ?", (FLAG_PINNED, mid))
                db.execute("INSERT INTO pins (conv, message, by, time) VALUES (?, ?, ?, ?)",
                           (c.id, mid, rng.choice(c.members), now_ms - rng.randint(0, 86_400_000 * 30)))
    # The last messages' edits and reactions came after them; not after now.
    db.execute("UPDATE messages SET edited = ?1 WHERE edited > ?1", (now_ms,))
    db.execute("UPDATE reactions SET time = ?1 WHERE time > ?1", (now_ms,))
    db.execute("UPDATE accounts SET last_seen = ?", (now_ms,))
    db.commit()


# ---------------------------------------------------------------------------


def size_arg(text):
    m = re.fullmatch(r"(\d+(?:\.\d+)?)\s*([KMGT]?)B?", text.strip(), re.I)
    if not m:
        raise argparse.ArgumentTypeError(f"not a size: {text}")
    return int(float(m.group(1)) * 1024 ** "_KMGT".index(m.group(2).upper() or "_"))


def db_bytes(db):
    pages = db.execute("PRAGMA page_count").fetchone()[0]
    size = db.execute("PRAGMA page_size").fetchone()[0]
    return pages * size


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter,
                                epilog="Sizes take K, M, G or T: 3G, 500M.")
    p.add_argument("data_dir", help="where yap.db and blobs/ are made")
    p.add_argument("--db-size", type=size_arg, default=size_arg("3G"),
                   help="stop when yap.db is this big (default 3G)")
    p.add_argument("--messages", type=int, default=0,
                   help="stop after this many messages instead of at a size")
    p.add_argument("--image-every", type=float, default=100,
                   help="one message in this many is a picture (default 100; 0 for none)")
    p.add_argument("--users", type=int, default=30)
    p.add_argument("--channels", type=int, default=20, help="public channels, the home one included (at most %d)" % len(CHANNEL_NAMES))
    p.add_argument("--dm-partners", type=int, default=6, help="how many people each person picks to DM (default 6)")
    p.add_argument("--dm-share", type=float, default=0.3, help="share of messages that are in DMs (default 0.3)")
    p.add_argument("--years", type=float, default=5, help="how far back the history goes (default 5)")
    p.add_argument("--thread-rate", type=float, default=0.15, help="share of channel bursts that are in a thread")
    p.add_argument("--mention-rate", type=float, default=0.04)
    p.add_argument("--reaction-rate", type=float, default=0.06)
    p.add_argument("--pool", type=int, default=300, help="different drawings the pictures are copies of (default 300)")
    p.add_argument("--password", default="password", help="everyone's password (default: password)")
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--jobs", type=int, default=os.cpu_count() or 4, help="processes drawing the picture pool")
    p.add_argument("--force", action="store_true", help="replace what's in data_dir")
    args = p.parse_args()
    args.image_rate = 1 / args.image_every if args.image_every > 0 else 0
    if not 8 <= len(args.password.encode()) <= 128:
        p.error("a password is 8 to 128 bytes")
    if args.users < 2:
        p.error("at least 2 users")

    db_path = os.path.join(args.data_dir, DB_FILE)
    blobs_path = os.path.join(args.data_dir, BLOBS_DIR)
    if os.path.exists(db_path) or os.path.exists(blobs_path):
        if not args.force:
            sys.exit(f"{args.data_dir} already has a yap.db or blobs/ (--force replaces them)")
        import shutil
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(db_path + suffix):
                os.remove(db_path + suffix)
        shutil.rmtree(blobs_path, ignore_errors=True)
    os.makedirs(args.data_dir, exist_ok=True)

    rng = random.Random(args.seed)
    began = time.monotonic()
    pool = []
    if args.image_rate:
        print(f"drawing {args.pool} pictures...", flush=True)
        pool = make_pool(args.pool, args.seed, args.jobs)
        avg = sum(len(j) for j, _, _ in pool) / len(pool)
        print(f"  {avg / 1024:.0f} KB each on average", flush=True)

    db = sqlite3.connect(db_path, isolation_level=None)
    db.execute("BEGIN")
    db.rollback()
    version = create_schema(db)
    # Fast and unsafe while it's made; it's checked and put as the server
    # wants it at the end.
    db.execute("PRAGMA journal_mode = OFF")
    db.execute("PRAGMA synchronous = OFF")
    db.execute("PRAGMA cache_size = -1048576")  # 1 GiB
    db.execute("PRAGMA temp_store = MEMORY")
    db.execute("BEGIN")

    now_ms = int(time.time() * 1000)
    start_ms = now_ms - int(args.years * 365.25 * 86_400_000)
    accounts = make_people(db, args, rng, start_ms)
    convs = make_convs(db, args, rng, accounts, start_ms)
    db.commit()
    db.execute("BEGIN")
    blobs = Blobs(db, args.data_dir)
    gen = Gen(args, db, rng, accounts, convs, pool, blobs)

    # How many messages there will be isn't known until the database is
    # that big, so it's guessed (at 230 bytes a message) and the guess
    # corrected as it grows; the time between messages follows it, so
    # the last ones are about now.
    target = args.messages or args.db_size // 230
    t = start_ms
    chunk = 50_000
    base_size = db_bytes(db)
    last_report = 0.0
    while True:
        remaining = max(1, target - gen.count)
        # A burst is ~6 messages, a minute or so apart, and takes its
        # share of the time left; the rest is quiet between bursts.
        per = gen.count / gen.bursts if gen.bursts else 5.5
        per_burst = max(2.0, (now_ms - t) / (remaining / per))
        within = min(90_000, per_burst / 20)
        between = max(1.0, per_burst - per * within)
        start_count = gen.count
        while gen.count - start_count < chunk:
            t = gen.burst(t, gap_ms=within)
            t += int(rng.expovariate(1 / between))
        gen.flush()
        db.execute("BEGIN")
        size = db_bytes(db)
        if not args.messages and gen.count >= 200_000:
            per = (size - base_size) / gen.count
            target = int((args.db_size - base_size) / per)
        if time.monotonic() - last_report > 5:
            last_report = time.monotonic()
            print(f"  {gen.count:,} messages, {blobs.count:,} pictures ({blobs.bytes / 2**30:.1f} GiB), "
                  f"yap.db {size / 2**30:.2f} GiB, {time.strftime('%Y-%m-%d', time.localtime(t / 1000))}",
                  flush=True)
        if args.messages and gen.count >= args.messages:
            break
        if not args.messages and size >= args.db_size:
            break
    db.commit()
    finish(db, gen, convs, rng, now_ms)

    print("checking, and switching to the log the server uses...", flush=True)
    problems = db.execute("PRAGMA foreign_key_check").fetchall()
    if problems:
        sys.exit(f"foreign key problems: {problems[:10]}")
    db.execute("PRAGMA journal_mode = WAL")
    db.close()

    size = os.path.getsize(db_path)
    print()
    print(f"made {args.data_dir} in {time.monotonic() - began:.0f} s (schema version {version}):")
    print(f"  yap.db     {size / 2**30:.2f} GiB")
    print(f"  messages   {gen.count:,}: {gen.kinds[MSG_TEXT] - gen.pictures:,} text, {gen.pictures:,} pictures, "
          f"{gen.kinds[MSG_FILE]:,} file offers; {len(gen.threads):,} threads; "
          f"{gen.text_bytes / gen.count if gen.count else 0:.0f} bytes of text each on average")
    print(f"  blobs/     {blobs.count:,} pictures, {blobs.bytes / 2**30:.2f} GiB")
    print(f"  accounts   {len(accounts)} ({', '.join(['admin', 'user01', '...'])}), password {args.password!r}")
    print(f"  convs      {sum(c.kind == CONV_CHANNEL for c in convs)} channels, {sum(c.kind == CONV_DM for c in convs)} DMs")
    print(f'\nPoint a server config\'s "data_dir" at {os.path.abspath(args.data_dir)} and start it.')


if __name__ == "__main__":
    main()
