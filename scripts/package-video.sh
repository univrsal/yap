#!/bin/sh
# Lays out the screen sharing add-on in dist/yap-video-<platform>/:
# yap_video, the FFmpeg libraries it uses and their licence, and
# yv-loopback. It's unpacked next to yap (D12 in misc/hq-share/README.md);
# without it the client runs as before, but neither shares nor watches.
# CI gathers the platforms' folders into one yap-video artifact, with
# linux/, macos/ and windows/ in it, which GitHub zips itself.
# Usage: scripts/package-video.sh <platform>
# Run after build-video.sh / build-video.bat.
set -e
cd "$(dirname "$0")/.."
platform=${1:?usage: package-video.sh <platform>}
name=yap-video-$platform
rm -rf "dist/$name"
mkdir -p "dist/$name"

if [ -f bin/yap_video.dll ]; then
	cp bin/yap_video.dll bin/yv-loopback.exe dist/$name/
	# Cameras, through DirectShow (src/video/thirdparty/dshowcapture).
	cp bin/dshowcapture.dll bin/dshowcapture-LICENSE.txt dist/$name/
	for lib in avcodec avutil swresample swscale; do
		cp bin/$lib-*.dll "dist/$name/"
	done
elif [ -f bin/libyap_video.dylib ]; then
	cp bin/libyap_video.dylib bin/yv-loopback "dist/$name/"
	# The libraries, and the links to them they're found by.
	for lib in avcodec avutil swscale; do
		cp -P bin/lib$lib.*dylib "dist/$name/"
	done
elif [ -f bin/libyap_video.so ]; then
	cp bin/libyap_video.so bin/yv-loopback "dist/$name/"
	for lib in avcodec avutil swresample swscale; do
		cp -P bin/lib$lib.so* "dist/$name/"
	done
else
	echo "no yap_video in bin/ to pack: build it first (build-video.sh, build-video.bat)" >&2
	exit 1
fi
cp bin/ffmpeg-LICENSE.txt "dist/$name/"

cat >"dist/$name/README.txt" <<'EOF'
yap's screen sharing add-on

Put everything here next to yap (yap.exe), in the same folder, and
start yap again: it can then share your screen and watch others'.

  yap_video          yap's screen sharing and camera library (zlib licence)
  avcodec, avutil,   FFmpeg, LGPL 2.1 or later; ffmpeg-LICENSE.txt says
  swscale, ...       which build and where its source is
  dshowcapture       (Windows) cameras, through DirectShow: OBS's
                     libdshowcapture, LGPL 2.1 or later
                     (dshowcapture-LICENSE.txt); its source is in yap's,
                     src/video/thirdparty/dshowcapture
  yv-loopback        a tool to try it on its own: yv-loopback --list

On macOS, what's downloaded is quarantined, and macOS refuses unsigned
libraries; clear that after unpacking with
  xattr -dr com.apple.quarantine <this folder>
EOF
echo "packed dist/$name"
