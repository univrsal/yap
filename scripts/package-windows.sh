#!/bin/sh
# Makes the Windows installer, dist/Yap-Setup-<arch>.exe, from
# scripts/yap.iss: the client, and the screen sharing add-on as a part
# that can be left out. Needs Inno Setup 6 or 7 (ISCC.exe on PATH or in
# its usual place).
# Usage: scripts/package-windows.sh <arch>
# Run in Git Bash after package.sh and package-video.sh. YAP_VERSION
# (e.g. v0.1.0) sets the version the installer shows.
set -e
cd "$(dirname "$0")/.."
arch=${1:?usage: package-windows.sh <arch>}

version=${YAP_VERSION#v}
version=${version:-dev}

client=dist/yap-windows-$arch
video=dist/yap-video-windows-$arch
for d in "$client" "$video"; do
	if [ ! -d "$d" ]; then
		echo "no $d: run package.sh and package-video.sh first" >&2
		exit 1
	fi
done

iscc=$(command -v iscc || command -v ISCC || true)
if [ -z "$iscc" ]; then
	for p in "$PROGRAMFILES (x86)" "$PROGRAMFILES" "$LOCALAPPDATA/Programs"; do
		for v in 7 6; do
			if [ -z "$iscc" ] && [ -f "$p/Inno Setup $v/ISCC.exe" ]; then
				iscc="$p/Inno Setup $v/ISCC.exe"
			fi
		done
	done
fi
if [ -z "$iscc" ]; then
	echo "no ISCC.exe: install Inno Setup (https://jrsoftware.org/isinfo.php)" >&2
	exit 1
fi

rm -f "dist/Yap-Setup-$arch.exe"
"$iscc" //Q \
	"//DAppVersion=$version" \
	"//DClientDir=$(cygpath -w "$client")" \
	"//DVideoDir=$(cygpath -w "$video")" \
	"//DOutputName=Yap-Setup-$arch" \
	scripts/yap.iss
echo "packed dist/Yap-Setup-$arch.exe"
