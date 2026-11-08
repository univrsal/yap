#!/bin/sh
# Copies the FFmpeg builds named in ffmpeg.version from BtbN's autobuild into a
# release of yap's own (tag ffmpeg_mirror_tag), which fetch.sh and
# build-video.bat try first. BtbN prunes its autobuilds, a release of ours
# stays. Run it after changing ffmpeg.version and before pushing; needs curl
# and the GitHub CLI (gh), logged in with write access. Checks the sums first.
# Usage: scripts/build/mirror-ffmpeg.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
eval "$(tr -d '\r' <"$here/ffmpeg.version")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
base=https://github.com/BtbN/FFmpeg-Builds/releases/download/$ffmpeg_release
files=
for spec in "$ffmpeg_win.zip $ffmpeg_win_sha256" "$ffmpeg_linux.tar.xz $ffmpeg_linux_sha256"; do
	set -- $spec
	echo "downloading $1" >&2
	curl -fL --retry 5 --retry-all-errors -o "$work/$1" "$base/$1"
	sum=$(sha256sum "$work/$1" | cut -d' ' -f1)
	if [ "$sum" != "$2" ]; then
		echo "$1: checksum mismatch (got $sum)" >&2
		exit 1
	fi
	files="$files $work/$1"
done
if gh release view "$ffmpeg_mirror_tag" -R univrsal/yap >/dev/null 2>&1; then
	# shellcheck disable=SC2086 # $files is two paths without spaces
	gh release upload "$ffmpeg_mirror_tag" $files --clobber -R univrsal/yap
else
	# shellcheck disable=SC2086
	gh release create "$ffmpeg_mirror_tag" $files -R univrsal/yap \
		--title "FFmpeg build mirror ($ffmpeg_mirror_tag)" \
		--notes "BtbN's LGPL shared FFmpeg builds ($ffmpeg_release), kept here so the build doesn't break when they prune theirs. FFmpeg's source: https://ffmpeg.org/releases/. See scripts/build/ffmpeg.version." \
		--latest=false
fi
