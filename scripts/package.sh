#!/bin/sh
# Packs a release archive: dist/yap-<platform>.zip holding the client, the
# server and the web build (web/, which yap-server -relay serves).
# Usage: scripts/package.sh <platform> <web-build-dir>
# Run after build.sh / build.bat; <web-build-dir> is web/build.sh's web/out.
set -e
cd "$(dirname "$0")/.."
platform=${1:?usage: package.sh <platform> <web-build-dir>}
web=${2:?usage: package.sh <platform> <web-build-dir>}

ext=
[ -f bin/yap.exe ] && ext=.exe

name=yap-$platform
rm -rf "dist/$name" "dist/$name.zip"
mkdir -p "dist/$name/web"
cp "bin/yap$ext" "bin/yap-server$ext" "dist/$name/"
# The page and its glue, not the object file the build leaves beside them.
cp "$web/index.html" "$web/index.js" "$web/index.wasm" "dist/$name/web/"
cp channels.example.json "dist/$name/"

cd dist
if command -v zip >/dev/null; then
	zip -qr "$name.zip" "$name"
else
	7z a -tzip -bso0 "$name.zip" "$name"
fi
echo "packed dist/$name.zip"
