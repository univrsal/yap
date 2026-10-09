#!/bin/sh
# Makes sure the libopus source is unpacked in <deps-dir>/opus-<version>,
# fetching and checking the release tarball if need be. macOS and OpenBSD
# build it into client/audio/opus (build.sh; Windows does the same in
# build.bat, Linux links the prebuilt libopus.a) and the web build
# compiles it for wasm (web/build.sh); the source is too big to keep in
# the repo (its DNN model data).
# Usage: scripts/fetch-opus.sh <deps-dir>
set -e
. "$(dirname "$0")/opus.version"
deps=${1:?usage: fetch-opus.sh <deps-dir>}
[ -d "$deps/opus-$opus_version" ] && exit 0
mkdir -p "$deps"
tarball=$deps/opus-$opus_version.tar.gz
if [ ! -f "$tarball" ]; then
	echo "fetching opus $opus_version"
	curl -fL --retry 3 -o "$tarball.part" "https://downloads.xiph.org/releases/opus/opus-$opus_version.tar.gz"
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
if [ "$sum" != "$opus_sha256" ]; then
	echo "$tarball: checksum mismatch (got $sum); delete it to fetch it again" >&2
	exit 1
fi
tar -xzf "$tarball" -C "$deps"
