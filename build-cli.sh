#!/bin/sh
# Builds bin/yap-cli, the terminal client (src/cli, docs/design/cli-client.md).
# It links the same C libraries as bin/yap, which ./build.sh builds, so that is
# run first if they are missing. Extra arguments go to Odin, e.g. -debug.
set -e
cd "$(dirname "$0")"
mkdir -p bin
if [ ! -f src/client/audio/miniaudio/libyap_audio.a ]; then
	./build.sh "$@"
fi
version_defines=$(sh scripts/build/version-defines.sh)
. scripts/build/collections.sh
# $version_defines is one word per define, so it's expanded unquoted.
odin build src/cli $collections -vet -strict-style -out:bin/yap-cli $version_defines "$@"
