#!/bin/sh
# Builds the FFmpeg yap_video uses on macOS (scripts/ffmpeg.version) into
# <deps-dir>/<name>, unless it's there already, and prints that folder.
# There are no LGPL macOS builds to fetch as on Windows and Linux, and
# Homebrew's is GPL and only works where Homebrew is, so it's built
# from source:
#
# - FFmpeg, LGPL, shared: libavcodec with only the H.264, HEVC and AV1
#   decoders (and their VideoToolbox decoding) and the VideoToolbox
#   H.264 and HEVC encoders, libavutil, libswscale. Install names are
#   @rpath/..., so the libraries work from wherever yap_video is.
# - dav1d (BSD), static, inside libavcodec: AV1 for Macs that can't
#   decode it themselves (before the M3).
#
# Takes a few minutes the first time. Needs Xcode's command line tools
# and `brew install pkg-config meson ninja` (and nasm on Intel Macs).
# Works on Linux too, without VideoToolbox, to try the script.
# Usage: scripts/build-ffmpeg-macos.sh <deps-dir>
set -e
here=$(cd "$(dirname "$0")" && pwd)
# Without the CRs a Windows checkout gives it (core.autocrlf).
eval "$(tr -d '\r' <"$here/ffmpeg.version")"
deps=${1:?usage: build-ffmpeg-macos.sh <deps-dir>}
name=$ffmpeg_source-$dav1d_source-$(uname -s | tr A-Z a-z)-$(uname -m)
if [ -f "$deps/$name/lib/pkgconfig/libavcodec.pc" ]; then
	echo "$deps/$name"
	exit 0
fi
for tool in cc make pkg-config meson ninja curl; do
	if ! command -v $tool >/dev/null 2>&1; then
		echo "building FFmpeg needs $tool: brew install pkg-config meson ninja" >&2
		exit 1
	fi
done
mkdir -p "$deps"
# Absolute, as the build moves about.
abs=$(cd "$deps" && pwd)
out=$abs/$name

# fetch <name> <url> <sha256> unpacks a checked tarball into $deps.
fetch() {
	tarball=$deps/$1.tar.xz
	if [ ! -f "$tarball" ]; then
		echo "fetching $1" >&2
		curl -fL --retry 5 --retry-all-errors --retry-delay 5 --connect-timeout 30 --speed-limit 1024 --speed-time 60 -o "$tarball.part" "$2"
		mv "$tarball.part" "$tarball"
	fi
	if command -v sha256sum >/dev/null; then
		sum=$(sha256sum "$tarball" | cut -d' ' -f1)
	else
		sum=$(shasum -a 256 "$tarball" | cut -d' ' -f1)
	fi
	if [ "$sum" != "$3" ]; then
		echo "$tarball: checksum mismatch (got $sum); delete it to fetch it again" >&2
		exit 1
	fi
	rm -rf "${deps:?}/$1"
	tar -xJf "$tarball" -C "$deps"
}

fetch "$dav1d_source" \
	"https://downloads.videolan.org/pub/videolan/dav1d/$dav1d_version/$dav1d_source.tar.xz" \
	"$dav1d_source_sha256"
fetch "$ffmpeg_source" "https://ffmpeg.org/releases/$ffmpeg_source.tar.xz" "$ffmpeg_source_sha256"

jobs=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
platform=
case $(uname -s) in
Darwin)
	# The same oldest macOS as yap_video (src/video/CMakeLists.txt).
	export MACOSX_DEPLOYMENT_TARGET=12.3
	platform="--enable-videotoolbox --install-name-dir=@rpath"
	;;
esac

# Everything goes to stderr: stdout is only for the folder.
{
	echo "building $dav1d_source"
	cd "$abs/$dav1d_source"
	meson setup build --prefix="$out" --libdir=lib --buildtype=release \
		--default-library=static -Denable_tools=false -Denable_tests=false \
		-Denable_examples=false
	ninja -C build install

	echo "building $ffmpeg_source"
	cd "$abs/$ffmpeg_source"
	# shellcheck disable=SC2086 # $platform is several options
	PKG_CONFIG_PATH="$out/lib/pkgconfig" ./configure --prefix="$out" \
		--enable-shared --disable-static --enable-pic \
		--disable-programs --disable-doc --disable-network \
		--disable-avdevice --disable-avformat --disable-avfilter --disable-swresample \
		--disable-autodetect --disable-everything \
		--enable-libdav1d \
		--enable-decoder=h264,hevc,av1,libdav1d \
		--enable-parser=h264,hevc,av1 \
		--enable-bsf=av1_frame_split,extract_extradata \
		--enable-encoder=h264_videotoolbox,hevc_videotoolbox \
		--enable-hwaccel=h264_videotoolbox,hevc_videotoolbox,av1_videotoolbox \
		$platform
	make -j"$jobs"
	make install

	# What has to go along with the libraries.
	{
		echo "FFmpeg ($ffmpeg_source), LGPL 2.1 or later."
		echo "Source: https://ffmpeg.org/releases/$ffmpeg_source.tar.xz"
		echo "Built by scripts/build-ffmpeg-macos.sh in yap's repository."
		echo
		cat COPYING.LGPLv2.1
		echo
		echo "dav1d ($dav1d_source), built into libavcodec:"
		echo
		cat "$abs/$dav1d_source/COPYING"
	} >"$out/LICENSE.txt"
} >&2
echo "$deps/$name"
