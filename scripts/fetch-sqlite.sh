#!/bin/sh
# Makes sure the SQLite source is unpacked in
# <deps-dir>/sqlite-autoconf-<version>, fetching and checking the release
# tarball if need be. The server links it (see src/server/sqlite and
# build.sh); the source is one file of nine megabytes, too big to keep in
# the repo. It's the "autoconf" tarball rather than the amalgamation's
# zip because tar is everywhere and unzip isn't; both hold the same
# sqlite3.c.
# Usage: scripts/fetch-sqlite.sh <deps-dir>
set -e
. "$(dirname "$0")/sqlite.version"
deps=${1:?usage: fetch-sqlite.sh <deps-dir>}
name=sqlite-autoconf-$sqlite_version
[ -f "$deps/$name/sqlite3.c" ] && exit 0
mkdir -p "$deps"
tarball=$deps/$name.tar.gz
if [ ! -f "$tarball" ]; then
	echo "fetching sqlite $sqlite_version"
	curl -fL --retry 3 -o "$tarball.part" "https://www.sqlite.org/$sqlite_year/$name.tar.gz"
	mv "$tarball.part" "$tarball"
fi
if command -v sha256sum >/dev/null; then
	sum=$(sha256sum "$tarball" | cut -d' ' -f1)
elif command -v sha256 >/dev/null; then
	# OpenBSD's.
	sum=$(sha256 -q "$tarball")
else
	sum=$(shasum -a 256 "$tarball" | cut -d' ' -f1)
fi
if [ "$sum" != "$sqlite_sha256" ]; then
	echo "$tarball: checksum mismatch (got $sum); delete it to fetch it again" >&2
	exit 1
fi
tar -xzf "$tarball" -C "$deps"
