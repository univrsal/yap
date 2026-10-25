#!/bin/sh
# Makes sure a third-party source or prebuilt package is unpacked in <deps-dir>,
# fetching and checking the release archive if need be. What each one is, and
# the version and checksum, is in <name>.version next to this script (read by
# build.bat too, so lines are name=value and nothing else).
#
#   opus    libopus source, in <deps-dir>/opus-<version>. macOS and OpenBSD
#           build it into client/audio/opus (build.sh; Windows does the same in
#           build.bat, Linux links the prebuilt libopus.a) and the web build
#           compiles it for wasm (web/build.sh); the source is too big to keep
#           in the repo (its DNN model data).
#   sqlite  the SQLite source, in <deps-dir>/sqlite-autoconf-<version>. The
#           server links it (see src/server/sqlite and build.sh); the source is
#           one file of nine megabytes. It's the "autoconf" tarball rather than
#           the amalgamation's zip because tar is everywhere and unzip isn't;
#           both hold the same sqlite3.c.
#   webp    libwebp source, in <deps-dir>/libwebp-<version>. build.sh builds it
#           into src/common/webp (build.bat does the same on Windows); a web
#           build leaves pictures to the browser and doesn't need it.
#   ffmpeg  a prebuilt FFmpeg for x86_64 Linux (scripts/build/ffmpeg.version),
#           in <deps-dir>/<name>. Prints that folder. Windows has
#           build-video.bat, macOS build-ffmpeg-macos.sh.
#
# Usage: scripts/build/fetch.sh <opus|sqlite|webp|ffmpeg> <deps-dir>
set -e
what=${1:?usage: fetch.sh <opus|sqlite|webp|ffmpeg> <deps-dir>}
deps=${2:?usage: fetch.sh <opus|sqlite|webp|ffmpeg> <deps-dir>}
here=$(dirname "$0")
unpack=-xzf
print=
case $what in
opus)
	. "$here/opus.version"
	dir=opus-$opus_version
	file=$dir.tar.gz
	url=https://downloads.xiph.org/releases/opus/$file
	sha=$opus_sha256
	marker=$dir
	;;
sqlite)
	. "$here/sqlite.version"
	dir=sqlite-autoconf-$sqlite_version
	file=$dir.tar.gz
	url=https://www.sqlite.org/$sqlite_year/$file
	sha=$sqlite_sha256
	marker=$dir/sqlite3.c
	;;
webp)
	. "$here/webp.version"
	dir=libwebp-$webp_version
	file=$dir.tar.gz
	url=https://storage.googleapis.com/downloads.webmproject.org/releases/webp/$file
	sha=$webp_sha256
	marker=$dir
	;;
ffmpeg)
	# Without the CRs a Windows checkout gives it (core.autocrlf).
	eval "$(tr -d '\r' <"$here/ffmpeg.version")"
	dir=$ffmpeg_linux
	file=$dir.tar.xz
	url=https://github.com/BtbN/FFmpeg-Builds/releases/download/$ffmpeg_release/$file
	sha=$ffmpeg_linux_sha256
	marker=$dir/include
	unpack=-xJf
	print=$deps/$dir
	;;
*)
	echo "fetch.sh: don't know $what" >&2
	exit 2
	;;
esac

if [ ! -e "$deps/$marker" ]; then
	mkdir -p "$deps"
	tarball=$deps/$file
	if [ ! -f "$tarball" ]; then
		echo "fetching $dir" >&2
		curl -fL --retry 5 --retry-all-errors --retry-delay 5 --connect-timeout 30 --speed-limit 1024 --speed-time 60 -o "$tarball.part" "$url"
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
	if [ "$sum" != "$sha" ]; then
		echo "$tarball: checksum mismatch (got $sum); delete it to fetch it again" >&2
		exit 1
	fi
	tar $unpack "$tarball" -C "$deps"
fi
[ -z "$print" ] || echo "$print"
