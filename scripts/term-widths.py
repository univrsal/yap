#!/usr/bin/env python3
"""Measures how many cells this terminal moves the cursor for some emoji.

Run it in the terminal itself (not in tmux) and again inside tmux, and compare:
where the two differ, a row with that emoji can come out shifted in yap-cli.

    python3 scripts/term-widths.py
"""
import os, re, select, sys, termios, tty

GLYPHS = "☀☁☂☃☎☔☕☘☝☠☢☮☯☸☹☺♀♂♨♻♿⚒⚓⚔⚕⚖⚗⚙⚛⚜⚠⚡⛅⛈⛏⛑⛓⛩⛰⛱⛴⛷⛸⛹✈✉✌✍✏✒✔✖✝✡✳✴❄❇❣❤➡⤴⤵⬅⬆⬇〰〽🌤🌥🌦🌧🌨🌩🌪🌫🌬🌶🍽🏋🏍🏎🏔🏕🏖🏗🏘🏙🏚🏛🏜🏝🏞🏟🏳👁🕴🕶🕷🕸🕹🖥🖨🖱🖲🗂🗃🗄🗑🗒🗓🗜🗝🗞🗡🗣🗨🗯🗳🗺🛋🛍🛎🛏🛠🛡🛢🛣🛤🛥🛩🛰🛳🍞🌞😎🏄🌻🍣"


def position(fd):
    os.write(fd, b"\x1b[6n")
    buf = b""
    while not buf.endswith(b"R"):
        if not select.select([fd], [], [], 2)[0]:
            return None
        buf += os.read(fd, 32)
    m = re.search(rb"\[(\d+);(\d+)R", buf)
    return int(m.group(2)) if m else None


def main():
    fd = sys.stdin.fileno()
    if not os.isatty(fd):
        sys.exit("run this in a terminal")
    old = termios.tcgetattr(fd)
    tty.setraw(fd)
    out = {}
    try:
        for g in GLYPHS:
            os.write(fd, b"\r\x1b[K" + g.encode())
            col = position(fd)
            out[g] = None if col is None else col - 1
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        sys.stdout.write("\r\x1b[K")
    for width in (0, 1, 2, None):
        glyphs = "".join(g for g, w in out.items() if w == width)
        if glyphs:
            print(f"{'no answer' if width is None else f'{width} cells'}: {glyphs}")
    print("TMUX" if os.environ.get("TMUX") else "not in tmux", os.environ.get("TERM", ""))


main()
