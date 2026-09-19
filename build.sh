#!/bin/sh
# Builds bin/yap-server and bin/yap-client. Extra arguments are passed to
# both builds, e.g. ./build.sh -debug -define:YAP_LOSS_PERCENT=30
#
# The client links a trimmed-down miniaudio (client/miniaudio), compiled
# here with the system C compiler ($CC, default cc) whenever its sources
# change.
set -e
cd "$(dirname "$0")"
mkdir -p bin

ma=client/miniaudio
lib=$ma/libyap_audio.a
if [ ! -f "$lib" ] || [ "$ma/yap_audio.c" -nt "$lib" ] || [ "$ma/yap_audio.h" -nt "$lib" ] || [ "$ma/miniaudio.h" -nt "$lib" ]; then
	echo "building $lib"
	${CC:-cc} -std=c99 -Os -c "$ma/yap_audio.c" -o "$ma/yap_audio.o"
	ar rcs "$lib" "$ma/yap_audio.o"
	rm "$ma/yap_audio.o"
fi

odin build server -vet -strict-style -out:bin/yap-server "$@"
odin build client -vet -strict-style -out:bin/yap-client "$@"
