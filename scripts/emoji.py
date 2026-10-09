#!/usr/bin/env python3
"""
Makes the emoji the client draws and both sides know of (phase 10):

  src/client/assets/emoji.webp        a sheet of those emoji's pictures, one
                                      64 pixel cell each, from a colour
                                      emoji font
  src/client/render/emoji_cells.odin  which character is in which cell
  src/common/proto/emoji_table.odin   those emoji: the character, its
                                      shortcodes and its category

The emoji are GitHub's gemoji list (MIT), those that are one character
(once a variation selector is dropped, as yap's text does), and that the
font has a picture for. Sequences (flags, skin tones, people joined with
U+200D) are left out: the text sanitizer drops the joiners, and each
emoji would need a picture of its own.

The font is Apple Color Emoji, in the build for Linux (the CBDT format,
which fontTools reads; the one from macOS is another format). Its pictures
are cut to 60 pixels and set in cells of 64: the margin keeps one's edge
from bleeding into the next when the sheet is shrunk (mipmaps). Colours
are carried out into the transparent pixels around each picture, so
filtering the edge doesn't pull in black.

All three outputs are committed; this is only run to bring them up to
date. It needs Python 3 with fontTools, Pillow (with WebP) and numpy, and
fetches the emoji list with curl.

	scripts/emoji.py AppleColorEmoji-Linux.ttf
"""

import argparse
import io
import json
import os
import subprocess
import sys
import tempfile

import numpy as np
from fontTools.ttLib import TTFont
from PIL import Image

LIST_URL = "https://raw.githubusercontent.com/github/gemoji/master/db/emoji.json"

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ATLAS_OUT = os.path.join(ROOT, "src/client/assets/emoji.webp")
CELLS_OUT = os.path.join(ROOT, "src/client/render/emoji_cells.odin")
TABLE_OUT = os.path.join(ROOT, "src/common/proto/emoji_table.odin")

# The sheet's layout, as src/client/render/emoji_atlas.odin has it. The
# last cell is left for a white texel (rects drawn between emoji).
CELL = 64
COLUMNS = 32
ROWS = 32
PADDING = 2
WEBP_QUALITY = 80

# gemoji's categories, as the table's enum names them, in picker order.
CATEGORIES = {
    "Smileys & Emotion": "Smileys",
    "People & Body": "People",
    "Animals & Nature": "Animals",
    "Food & Drink": "Food",
    "Travel & Places": "Travel",
    "Activities": "Activities",
    "Objects": "Objects",
    "Symbols": "Symbols",
    "Flags": "Flags",
}


def fetch(url, path):
    subprocess.run(["curl", "-sSfL", "-o", path, url], check=True)


def pictures(font):
    """The font's pictures by character: the largest strike's."""
    cbdt, cblc = font["CBDT"], font["CBLC"]
    strike = max(range(len(cblc.strikes)), key=lambda i: cblc.strikes[i].bitmapSizeTable.ppemY)
    bitmaps = cbdt.strikeData[strike]
    result = {}
    for cp, name in font.getBestCmap().items():
        if name in bitmaps:
            try:
                image = Image.open(io.BytesIO(bitmaps[name].imageData)).convert("RGBA")
                image.load()
            except Exception:
                continue
            result[cp] = image
    return result


def bleed(rgba, passes):
    """Carries colour from the picture's edge out into its transparent
    surroundings, a pixel a pass, so a filtered edge is its own colour."""
    rgb = rgba[..., :3].astype(np.float32)
    have = rgba[..., 3] > 0
    for _ in range(passes):
        total = np.zeros_like(rgb)
        count = np.zeros(have.shape, np.float32)
        padded_rgb = np.pad(rgb, ((1, 1), (1, 1), (0, 0)))
        padded_have = np.pad(have, 1)
        h, w = have.shape
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dy == 0 and dx == 0:
                    continue
                part = padded_have[1 + dy:1 + dy + h, 1 + dx:1 + dx + w]
                total += padded_rgb[1 + dy:1 + dy + h, 1 + dx:1 + dx + w] * part[..., None]
                count += part
        fill = ~have & (count > 0)
        rgb[fill] = total[fill] / count[fill][:, None]
        have = have | fill
    out = rgba.copy()
    out[..., :3] = np.rint(rgb).astype(np.uint8)
    return out


def tile_of(image):
    available = CELL - 2 * PADDING
    image = image.copy()
    image.thumbnail((available, available), Image.Resampling.LANCZOS)
    tile = Image.new("RGBA", (CELL, CELL), (0, 0, 0, 0))
    tile.alpha_composite(image, ((CELL - image.width) // 2, (CELL - image.height) // 2))
    return bleed(np.asarray(tile), PADDING + 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("font", help="the colour emoji font (CBDT)")
    args = parser.parse_args()

    font = TTFont(args.font)
    if "CBDT" not in font or "CBLC" not in font:
        parser.error("the font must have CBDT and CBLC tables")
    have = pictures(font)

    with tempfile.TemporaryDirectory() as tmp:
        list_path = os.path.join(tmp, "emoji.json")
        fetch(LIST_URL, list_path)
        entries = []
        seen = set()
        for e in json.load(open(list_path, encoding="utf-8")):
            chars = e["emoji"].replace("️", "")
            if len(chars) != 1:
                continue
            r = ord(chars)
            if r in seen or r not in have or not e["aliases"]:
                continue
            seen.add(r)
            names = [a for a in e["aliases"] if all(c.isalnum() or c in "_+-" for c in a)]
            if not names:
                continue
            entries.append((r, " ".join(names), CATEGORIES[e["category"]]))

    # A cell each, in the order of the characters (the renderer looks
    # them up by binary search, and the index is the cell).
    runes = sorted(r for r, _, _ in entries)
    if len(runes) > COLUMNS * ROWS - 1:
        sys.exit("too many emoji for the sheet: %d" % len(runes))

    sheet = np.zeros((ROWS * CELL, COLUMNS * CELL, 4), np.uint8)
    for cell, r in enumerate(runes):
        x, y = (cell % COLUMNS) * CELL, (cell // COLUMNS) * CELL
        sheet[y:y + CELL, x:x + CELL] = tile_of(have[r])
    Image.fromarray(sheet, "RGBA").save(
        ATLAS_OUT, "WEBP", quality=WEBP_QUALITY, alpha_quality=100, method=6
    )

    with open(CELLS_OUT, "w", encoding="utf-8") as out:
        out.write("// Generated by scripts/emoji.py: don't edit; run the script.\n")
        out.write("package render\n\n")
        out.write("// The characters in the emoji sheet (assets/emoji.webp), in order: a\n")
        out.write("// character's index is its cell.\n")
        out.write("@(rodata)\nEMOJI_CELLS := [?]rune{")
        for i, r in enumerate(runes):
            out.write("%s0x%X," % ("\n\t" if i % 12 == 0 else " ", r))
        out.write("\n}\n")

    with open(TABLE_OUT, "w", encoding="utf-8") as out:
        out.write("// Generated by scripts/emoji.py from GitHub's gemoji list (MIT):\n")
        out.write("// see src/client/licenses/gemoji.txt. Don't edit; run the script.\n")
        out.write("package proto\n\n")
        out.write("Emoji_Category :: enum u8 {\n")
        for name in CATEGORIES.values():
            out.write("\t%s,\n" % name)
        out.write("}\n\n")
        out.write("// The emoji there are, in picker order: the character, its shortcodes\n")
        out.write("// (the first is its name), and its category.\n")
        out.write("@(rodata)\nEMOJI := [?]Emoji{\n")
        for r, names, category in entries:
            out.write('\t{0x%X, "%s", .%s},\n' % (r, names, category))
        out.write("}\n\n")
        out.write("// The same characters in order, with where each is in EMOJI, to look\n")
        out.write("// one up (emoji_index).\n")
        out.write("@(rodata)\nEMOJI_BY_RUNE := [?]Emoji_Ref{\n")
        for i, (r, _, _) in sorted(enumerate(entries), key=lambda e: e[1][0]):
            out.write("\t{0x%X, %d},\n" % (r, i))
        out.write("}\n")
    print(
        "%d emoji; sheet %d bytes" % (len(entries), os.path.getsize(ATLAS_OUT)),
        file=sys.stderr,
    )


main()
