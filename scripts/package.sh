#!/bin/sh
# Lays out a release in dist/yap-<platform>/: the client, the server and
# the web build (web/, which yap-server's relay serves). CI uploads the
# folder as an artifact, which GitHub zips itself, and the release
# workflow zips it for the release.
# Usage: scripts/package.sh <platform> <web-build-dir>
# Run after build.sh / build.bat; <web-build-dir> is web/build.sh's web/out.
set -e
cd "$(dirname "$0")/.."
platform=${1:?usage: package.sh <platform> <web-build-dir>}
web=${2:?usage: package.sh <platform> <web-build-dir>}

ext=
[ -f bin/yap.exe ] && ext=.exe

name=yap-$platform
rm -rf "dist/$name"
mkdir -p "dist/$name/web"
cp "bin/yap$ext" "bin/yap-server$ext" "dist/$name/"
# The page and its glue, not the object file the build leaves beside them.
cp "$web/index.html" "$web/index.js" "$web/index.wasm" "$web/favicon.ico" "dist/$name/web/"
cp config.example.json "dist/$name/"
echo "packed dist/$name"
