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
if [ ! -f "$lib" ] || [ -n "$(find "$rnn/yap_rnn.c" "$rnn/yap_rnn.h" deps/thirdparty/rnnoise -newer "$lib" | head -n 1)" ]; then
	echo "building $lib"
	${CC:-cc} -std=c99 -Os -c "$rnn/yap_rnn.c" -o "$rnn/yap_rnn.o"
	ar rcs "$lib" "$rnn/yap_rnn.o"
	rm "$rnn/yap_rnn.o"
fi

# traycon, for the tray icon. On Linux and the BSDs it needs the
# libdbus-1/libX11 dev headers to compile against (dlopen'd at runtime,
# not linked -- see traycon_dl.h), found through pkg-config: OpenBSD
# keeps X11 in /usr/X11R6, off the compiler's default path. On macOS it's
# Cocoa, so it has to be built as Objective-C.
tray=src/client/tray
lib=$tray/libyap_tray.a
if [ ! -f "$lib" ] || [ "$tray/yap_tray.c" -nt "$lib" ] || [ deps/thirdparty/traycon/traycon.h -nt "$lib" ] || [ deps/thirdparty/traycon/traycon_dl.h -nt "$lib" ]; then
	echo "building $lib"
	case "$(uname -s)" in
	Darwin) tray_flags="-x objective-c" ;;
	# strdup is POSIX rather than C99, so it has to be asked for.
	*) tray_flags="-D_POSIX_C_SOURCE=200809L $(pkg-config --cflags dbus-1 x11)" ;;
	esac
	${CC:-cc} -std=c99 -Os $tray_flags -c "$tray/yap_tray.c" -o "$tray/yap_tray.o"
	ar rcs "$lib" "$tray/yap_tray.o"
	rm "$tray/yap_tray.o"
fi

# libopus on macOS and OpenBSD: there's no prebuilt library for them in
# src/client/opus, so it's built from the release source
# (scripts/fetch-opus.sh), the float API without DRED or OSCE, which is
# what src/client/opus binds.
case "$(uname -s)" in
Darwin) opus_os=macos ;;
OpenBSD) opus_os=openbsd ;;
*) opus_os= ;;
esac
if [ -n "$opus_os" ] && [ ! -f "src/client/opus/libopus_$opus_os.a" ]; then
	scripts/fetch-opus.sh .cache
	echo "building src/client/opus/libopus_$opus_os.a"
	cmake -S .cache/opus-1.6 -B ".cache/opus-$opus_os" \
		-DCMAKE_BUILD_TYPE=Release \
		-DOPUS_BUILD_PROGRAMS=OFF \
		-DOPUS_BUILD_TESTING=OFF \
		-DOPUS_HARDENING=OFF \
		-DOPUS_INSTALL_PKG_CONFIG_MODULE=OFF \
		-DOPUS_INSTALL_CMAKE_CONFIG_MODULE=OFF >/dev/null
	# A job count, since OpenBSD's make won't take a bare -j.
	jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || getconf NPROCESSORS_ONLN)
	cmake --build ".cache/opus-$opus_os" --parallel "$jobs"
	cp ".cache/opus-$opus_os/libopus.a" "src/client/opus/libopus_$opus_os.a"
fi

# OpenBSD: two libraries Odin's own packages ask the linker for aren't
# there. vendor:stb only links its prebuilt vendor/stb/lib on Linux and
# macOS and wants system libraries anywhere else, so the ones the client
# uses are built here from Odin's copy of the source. And core:sys/posix
# links libdl, which OpenBSD doesn't have (dlopen is in libc), so an
# empty one stands in for it.
client_link_flags=
if [ "$(uname -s)" = OpenBSD ]; then
	bsd_libs=.cache/openbsd-libs
	stb_src="$(odin root)/vendor/stb/src"
	mkdir -p "$bsd_libs"
	for name in stb_image stb_image_resize stb_image_write stb_truetype; do
		if [ ! -f "$bsd_libs/lib$name.a" ]; then
			echo "building $bsd_libs/lib$name.a"
			${CC:-cc} -O2 -fPIC -c "$stb_src/$name.c" -o "$bsd_libs/$name.o"
			ar rcs "$bsd_libs/lib$name.a" "$bsd_libs/$name.o"
			rm "$bsd_libs/$name.o"
		fi
	done
	[ -f "$bsd_libs/libdl.a" ] || ar rcs "$bsd_libs/libdl.a"
	client_link_flags="-extra-linker-flags:-L$bsd_libs"
fi

# The version and commit (src/common/version.odin); one word per define,
# so it's expanded unquoted.
version_defines=$(scripts/version-defines.sh)
odin build src/server -vet -strict-style -out:bin/yap-server $version_defines "$@"
odin build src/client -vet -strict-style -out:bin/yap $client_link_flags $version_defines "$@"
