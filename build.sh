#!/bin/sh
# Builds bin/yap-server (whose relay lets the web client reach it; the
# web client itself is web/build.sh) and bin/yap.
# Extra arguments are passed to both builds, e.g.
# ./build.sh -debug -define:YAP_LOSS_PERCENT=30
#
# The client links a trimmed-down miniaudio (src/client/miniaudio), RNNoise
# (src/client/rnn) and traycon (src/client/tray), whose third-party sources
# are in deps/thirdparty, compiled here with the system C
# compiler ($CC, default cc) whenever their sources change.
set -e
cd "$(dirname "$0")"
mkdir -p bin

ma=src/client/miniaudio
lib=$ma/libyap_audio.a
if [ ! -f "$lib" ] || [ "$ma/yap_audio.c" -nt "$lib" ] || [ "$ma/yap_audio.h" -nt "$lib" ] || [ deps/thirdparty/miniaudio/miniaudio.h -nt "$lib" ]; then
	echo "building $lib"
	${CC:-cc} -std=c99 -Os -c "$ma/yap_audio.c" -o "$ma/yap_audio.o"
	ar rcs "$lib" "$ma/yap_audio.o"
	rm "$ma/yap_audio.o"
fi

rnn=src/client/rnn
lib=$rnn/libyap_rnn.a
if [ ! -f "$lib" ] || [ -n "$(find "$rnn/yap_rnn.c" "$rnn/yap_rnn.h" deps/thirdparty/rnnoise -newer "$lib" -print -quit)" ]; then
	echo "building $lib"
	${CC:-cc} -std=c99 -Os -c "$rnn/yap_rnn.c" -o "$rnn/yap_rnn.o"
	ar rcs "$lib" "$rnn/yap_rnn.o"
	rm "$rnn/yap_rnn.o"
fi

# traycon, for the tray icon. On Linux it needs the libdbus-1/libX11
# dev headers to compile against (dlopen'd at runtime, not linked -- see
# traycon_dl.h); on macOS it's Cocoa, so it has to be built as
# Objective-C.
tray=src/client/tray
lib=$tray/libyap_tray.a
if [ ! -f "$lib" ] || [ "$tray/yap_tray.c" -nt "$lib" ] || [ deps/thirdparty/traycon/traycon.h -nt "$lib" ] || [ deps/thirdparty/traycon/traycon_dl.h -nt "$lib" ]; then
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

# libopus on macOS: there's no prebuilt library for it in src/client/opus, so
# it's built from the release source (scripts/fetch-opus.sh), the float
# API without DRED or OSCE, which is what src/client/opus binds.
if [ "$(uname -s)" = Darwin ] && [ ! -f src/client/opus/libopus_macos.a ]; then
	scripts/fetch-opus.sh .cache
	echo "building src/client/opus/libopus_macos.a"
	cmake -S .cache/opus-1.6 -B .cache/opus-macos \
		-DCMAKE_BUILD_TYPE=Release \
		-DOPUS_BUILD_PROGRAMS=OFF \
		-DOPUS_BUILD_TESTING=OFF \
		-DOPUS_HARDENING=OFF \
		-DOPUS_INSTALL_PKG_CONFIG_MODULE=OFF \
		-DOPUS_INSTALL_CMAKE_CONFIG_MODULE=OFF >/dev/null
	cmake --build .cache/opus-macos --parallel
	cp .cache/opus-macos/libopus.a src/client/opus/libopus_macos.a
fi

# The version and commit (src/common/version.odin); one word per define,
# so it's expanded unquoted.
version_defines=$(scripts/version-defines.sh)
odin build src/server -vet -strict-style -out:bin/yap-server $version_defines "$@"
odin build src/client -vet -strict-style -out:bin/yap $version_defines "$@"
