#!/usr/bin/env python3
"""
Makes src/client/spell/catalog.odin: the Hunspell dictionaries that the client
offers to download where it checks spelling with Hunspell (Linux and the BSDs),
from wooorm/dictionaries (https://github.com/wooorm/dictionaries) at one
commit. For each language it lists the files' URLs at that commit, their sizes
and SHA-256 hashes, and the dictionary's license, so the client only installs
what was listed here.

Dictionaries without a license file are left out. The output is committed;
this is only run to move to a newer commit. It downloads every dictionary once
to hash it (about 300 MB), and needs nothing beyond Python 3.

	tools/spell_catalog.py [commit]     (default: the newest on main)
"""

import concurrent.futures
import hashlib
import json
import os
import sys
import urllib.request

REPO = "wooorm/dictionaries"
OUT = os.path.join(os.path.dirname(__file__), "..", "src", "client", "spell", "catalog.odin")


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "spell-catalog"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


def file_info(commit, path):
    data = fetch(f"https://raw.githubusercontent.com/{REPO}/{commit}/{path}")
    return {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def entry(commit, name):
    base = f"dictionaries/{name}/"
    package = json.loads(fetch(f"https://raw.githubusercontent.com/{REPO}/{commit}/{base}package.json"))
    return {
        "name": name,
        "spdx": package.get("license", ""),
        "aff": file_info(commit, base + "index.aff"),
        "dic": file_info(commit, base + "index.dic"),
        "license": file_info(commit, base + "license"),
    }


def main():
    commit = sys.argv[1] if len(sys.argv) > 1 else json.loads(fetch(f"https://api.github.com/repos/{REPO}/commits/main"))["sha"]
    tree = json.loads(fetch(f"https://api.github.com/repos/{REPO}/git/trees/{commit}?recursive=1"))["tree"]
    files = {}
    for e in tree:
        parts = e["path"].split("/")
        if len(parts) == 3 and parts[0] == "dictionaries":
            files.setdefault(parts[1], set()).add(parts[2])
    names = sorted(n for n, f in files.items() if {"index.aff", "index.dic", "license", "package.json"} <= f)
    skipped = sorted(n for n in files if n not in names)
    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        entries = list(pool.map(lambda n: entry(commit, n), names))

    out = []
    w = out.append
    w("// Made by tools/spell_catalog.py from wooorm/dictionaries; don't edit.")
    w("package spell")
    w("")
    w("// Where the catalog's files are: <CATALOG_BASE><Catalog_Entry.dir>/index.aff and")
    w("// the like, at the commit the catalog was made from.")
    w(f'CATALOG_BASE :: "https://raw.githubusercontent.com/{REPO}/{commit}/dictionaries/"')
    w("")
    w("// The Hunspell dictionaries that can be downloaded (download.odin).")
    w("CATALOG := [?]Catalog_Entry {")
    for e in entries:
        w("\t{")
        w(f'\t\tdir = "{e["name"]}",')
        w(f'\t\tlicense = "{e["spdx"]}",')
        for key in ("aff", "dic", "license"):
            f = e[key]
            field = "license_file" if key == "license" else key
            w(f'\t\t{field} = {{{f["size"]}, "{f["sha256"]}"}},')
        w("\t},")
    w("}")
    with open(OUT, "w", newline="\n") as f:
        f.write("\n".join(out) + "\n")
    total = sum(e["aff"]["size"] + e["dic"]["size"] for e in entries)
    print(f"{len(entries)} dictionaries ({total / 1e6:.0f} MB) at {commit}; left out: {', '.join(skipped)}")


if __name__ == "__main__":
    main()
