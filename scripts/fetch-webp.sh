#!/bin/sh
# Makes sure the libwebp source is unpacked in <deps-dir>/libwebp-<version>,
# fetching and checking the release tarball if need be. build.sh builds
# it into src/common/webp (build.bat does the same on Windows); a web
# build leaves pictures to the browser and doesn't need it.
# Usage: scripts/fetch-webp.sh <deps-dir>
set -e
. "$(dirname "$0")/webp.version"
deps=${1:?usage: fetch-webp.sh <deps-dir>}
[ -d "$deps/libwebp-$webp_version" ] && exit 0
mkdir -p "$deps"
tarball=$deps/libwebp-$webp_version.tar.gz
if [ ! -f "$tarball" ]; then
	echo "fetching libwebp $webp_version"
	curl -fL --retry 3 -o "$tarball.part" "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$webp_version.tar.gz"
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
if [ "$sum" != "$webp_sha256" ]; then
	echo "$tarball: checksum mismatch (got $sum); delete it to fetch it again" >&2
	exit 1
fi
tar -xzf "$tarball" -C "$deps"
