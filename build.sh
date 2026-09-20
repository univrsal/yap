#!/bin/sh
# Builds bin/yap-server and bin/yap-client. Extra arguments are passed to
# both builds, e.g. ./build.sh -debug -define:YAP_LOSS_PERCENT=30
#
# The client links a trimmed-down miniaudio (client/miniaudio), RNNoise
# (client/rnn) and traycon (client/tray), compiled here with the system C
# compiler ($CC, default cc) whenever their sources change.
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

rnn=client/rnn
lib=$rnn/libyap_rnn.a
if [ ! -f "$lib" ] || [ -n "$(find "$rnn/yap_rnn.c" "$rnn/yap_rnn.h" "$rnn/impl" -newer "$lib" -print -quit)" ]; then
	echo "building $lib"
	${CC:-cc} -std=c99 -Os -c "$rnn/yap_rnn.c" -o "$rnn/yap_rnn.o"
	ar rcs "$lib" "$rnn/yap_rnn.o"
	rm "$rnn/yap_rnn.o"
fi

# traycon, for the tray icon. On Linux it needs libdbus-1 and libX11; on
# macOS it's Cocoa, so it has to be built as Objective-C.
tray=client/tray
lib=$tray/libyap_tray.a
if [ ! -f "$lib" ] || [ "$tray/yap_tray.c" -nt "$lib" ] || [ "$tray/traycon.h" -nt "$lib" ]; then
	echo "building $lib"
	case "$(uname -s)" in
	Darwin) tray_flags="-x objective-c" ;;
	# strdup is POSIX rather than C99, so it has to be asked for.
	*) tray_flags="-D_POSIX_C_SOURCE=200809L $(pkg-config --cflags dbus-1)" ;;
	esac
	${CC:-cc} -std=c99 -Os $tray_flags -c "$tray/yap_tray.c" -o "$tray/yap_tray.o"
	ar rcs "$lib" "$tray/yap_tray.o"
	rm "$tray/yap_tray.o"
fi

odin build server -vet -strict-style -out:bin/yap-server "$@"
odin build client -vet -strict-style -out:bin/yap-client "$@"
