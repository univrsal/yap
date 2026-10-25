#!/bin/sh
# Makes sure a prebuilt FFmpeg (scripts/build/ffmpeg.version) is unpacked in
# <deps-dir>/<name>, fetching and checking it if need be, and prints that
# folder. Only for x86_64 Linux; Windows has build-video.bat, macOS
# build-ffmpeg-macos.sh.
# Usage: scripts/build/fetch-ffmpeg.sh <deps-dir>
set -e
# Without the CRs a Windows checkout gives it (core.autocrlf).
eval "$(tr -d '\r' <"$(dirname "$0")/ffmpeg.version")"
deps=${1:?usage: fetch-ffmpeg.sh <deps-dir>}
name=$ffmpeg_linux
if [ -d "$deps/$name/include" ]; then
	echo "$deps/$name"
	exit 0
fi
mkdir -p "$deps"
tarball=$deps/$name.tar.xz
if [ ! -f "$tarball" ]; then
	echo "fetching $name" >&2
	curl -fL --retry 5 --retry-all-errors --retry-delay 5 --connect-timeout 30 --speed-limit 1024 --speed-time 60 -o "$tarball.part" "https://github.com/BtbN/FFmpeg-Builds/releases/download/$ffmpeg_release/$name.tar.xz"
	mv "$tarball.part" "$tarball"
fi
if command -v sha256sum >/dev/null; then
	sum=$(sha256sum "$tarball" | cut -d' ' -f1)
else
	sum=$(shasum -a 256 "$tarball" | cut -d' ' -f1)
fi
if [ "$sum" != "$ffmpeg_linux_sha256" ]; then
	echo "$tarball: checksum mismatch (got $sum); delete it to fetch it again" >&2
	exit 1
fi
tar -xJf "$tarball" -C "$deps"
echo "$deps/$name"
