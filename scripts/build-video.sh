#!/bin/sh
# Builds the optional screen sharing library, yap_video
# (src/video, misc/hq-share/README.md), and yv-loopback, into bin/ next
# to the client, with FFmpeg's libraries beside them. The client runs
# without any of it. On Linux build.sh links the library into the client
# itself, so there this is for the tool and for FFmpeg's libraries (the
# Linux yap-video download), and the client ignores bin/libyap_video.so.
# Needs CMake and a C++20 compiler. Extra arguments go to CMake's
# configure step.
#
# On Linux, capturing needs headers to build (the libraries themselves
# are only loaded at run time): libxcb1-dev libxcb-shm0-dev
# libxcb-randr0-dev libxcb-composite0-dev libxcb-xfixes0-dev for X11,
# libglib2.0-dev libpipewire-0.3-dev for Wayland's portal, and
# libva-dev for its pictures to reach VA-API without a copy.
set -e
cd "$(dirname "$0")/.."
# A folder per system, so a WSL build doesn't trip over a Windows one.
build=.cache/video-build-$(uname -s)
case "$(uname -s)-$(uname -m)" in
Linux-x86_64)
	ffmpeg=$(scripts/fetch-ffmpeg.sh .cache)
	set -- -DFFMPEG_DIR="$PWD/$ffmpeg" "$@"
	;;
Darwin-*)
	# Built from source the first time, which takes a few minutes.
	ffmpeg=$(scripts/build-ffmpeg-macos.sh .cache)
	set -- -DFFMPEG_DIR="$PWD/$ffmpeg" "$@"
	;;
*)
	# The system's FFmpeg, found by pkg-config.
	ffmpeg=
	if ! command -v pkg-config >/dev/null 2>&1 ||
		! pkg-config --exists libavcodec libavutil libswscale; then
		echo "no FFmpeg that pkg-config can find (libavcodec, libavutil, libswscale)" >&2
		exit 1
	fi
	;;
esac
cmake -S src/video -B "$build" -DCMAKE_BUILD_TYPE=Release "$@"
cmake --build "$build" --parallel
cmake --install "$build" --prefix bin
if [ -n "$ffmpeg" ]; then
	# Only the libraries yap_video links, and what they link, and the
	# licence that has to go with them.
	for lib in avcodec avutil swresample swscale; do
		for f in "$ffmpeg"/lib/lib$lib.so* "$ffmpeg"/lib/lib$lib.*dylib; do
			if [ -e "$f" ]; then
				cp -P "$f" bin/
			fi
		done
	done
	cp "$ffmpeg/LICENSE.txt" bin/ffmpeg-LICENSE.txt
fi
echo "built bin/yv-loopback and yap_video; try: bin/yv-loopback --list"
