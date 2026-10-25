#!/bin/sh
# Builds bin/yap-server (whose relay lets the web client reach it; the
# web client itself is web/build.sh) and bin/yap.
# Extra arguments are passed to both builds, e.g.
# ./build.sh -debug -define:YAP_LOSS_PERCENT=30
#
# The server links SQLite (src/server/sqlite), whose source is fetched
# into .cache the first time; both link libwebp (src/common/webp) the
# same way, built with CMake (scripts/build/build-webp.sh).
#
# The client links a trimmed-down miniaudio (src/client/audio/miniaudio), RNNoise
# (src/client/audio/rnn) and traycon (src/client/tray), whose third-party sources
# are in deps/thirdparty, compiled here with the system C
# compiler ($CC, default cc) whenever their sources change. On Linux it
# also links screen sharing (src/video), built with CMake and the C++
# compiler (see below).
set -e
cd "$(dirname "$0")"
mkdir -p bin

# The small C libraries in src/client: <dir>/yap_<name>.c compiled into
# <dir>/libyap_<name>.a.
# c_lib_stale <dir> <name> <dependency>...: true (and says so) when the
# library is missing or older than its source, its header or a dependency (a
# file, or a folder with files in it).
c_lib_stale() {
	_dir=$1 _name=$2
	shift 2
	_lib=$_dir/libyap_$_name.a
	if [ -f "$_lib" ] && [ -z "$(find "$_dir/yap_$_name.c" "$_dir/yap_$_name.h" "$@" -newer "$_lib" 2>/dev/null | head -n 1)" ]; then
		return 1
	fi
	echo "building $_lib"
}
# c_lib_build <dir> <name> <compiler flag>...
c_lib_build() {
	_dir=$1 _name=$2
	shift 2
	${CC:-cc} "$@" -c "$_dir/yap_$_name.c" -o "$_dir/yap_$_name.o"
	ar rcs "$_dir/libyap_$_name.a" "$_dir/yap_$_name.o"
	rm "$_dir/yap_$_name.o"
}

ma=src/client/audio/miniaudio
if c_lib_stale $ma audio deps/thirdparty/miniaudio/miniaudio.h; then
	c_lib_build $ma audio -std=c99 -Os
fi

rnn=src/client/audio/rnn
if c_lib_stale $rnn rnn deps/thirdparty/rnnoise; then
	c_lib_build $rnn rnn -std=c99 -Os
fi

# traycon, for the tray icon. On Linux and the BSDs it needs the
# libdbus-1/libX11 dev headers to compile against (dlopen'd at runtime,
# not linked -- see traycon_dl.h), found through pkg-config: OpenBSD
# keeps X11 in /usr/X11R6, off the compiler's default path. On macOS it's
# Cocoa, so it has to be built as Objective-C.
tray=src/client/tray
if c_lib_stale $tray tray deps/thirdparty/traycon/traycon.h deps/thirdparty/traycon/traycon_dl.h; then
	case "$(uname -s)" in
	Darwin) tray_flags="-x objective-c" ;;
	# strdup is POSIX rather than C99, so it has to be asked for.
	*) tray_flags="-D_POSIX_C_SOURCE=200809L $(pkg-config --cflags dbus-1 x11)" ;;
	esac
	c_lib_build $tray tray -std=c99 -Os $tray_flags
fi

# tinydialogs, for picking a file to send in a DM. It runs zenity or
# kdialog on Linux and the BSDs, so nothing to compile against there; on
# macOS it's Cocoa, so it has to be built as Objective-C.
dialogs=src/client/dialogs
if c_lib_stale $dialogs dialogs deps/thirdparty/tinydialogs/tinydialogs.h; then
	case "$(uname -s)" in
	Darwin) dialogs_flags="-x objective-c" ;;
	# popen and pclose are POSIX rather than C99.
	*) dialogs_flags="-D_POSIX_C_SOURCE=200809L" ;;
	esac
	c_lib_build $dialogs dialogs -std=c11 -Os $dialogs_flags
fi

# tinyaac, for sharing an application's audio. On Linux it needs the
# libpipewire-0.3 dev headers to compile against (dlopen'd at runtime,
# not linked -- see yap_aac.c); on macOS it's Core Audio and AppKit, so
# it has to be built as Objective-C, with ARC as tinyaac.h asks. The BSDs get tinyaac's stub,
# which says application audio is unavailable.
aac=src/client/audio/aac
if c_lib_stale $aac aac deps/thirdparty/tinyaac/tinyaac.h; then
	case "$(uname -s)" in
	Darwin) aac_flags="-x objective-c -fobjc-arc" ;;
	Linux) aac_flags="$(pkg-config --cflags libpipewire-0.3)" ;;
	*) aac_flags= ;;
	esac
	c_lib_build $aac aac -std=c99 -Os $aac_flags
fi

# How long since the last input on the desktop (src/client/idle), on
# Linux only: Wayland's ext-idle-notify-v1 or X11's libXss, both loaded
# with dlopen() at runtime, so nothing to compile against. Windows and
# macOS need no C for it.
if [ "$(uname -s)" = Linux ]; then
	idle=src/client/idle
	if c_lib_stale $idle idle; then
		c_lib_build $idle idle -std=c99 -Os -D_POSIX_C_SOURCE=200809L
	fi
fi

# Screen sharing (src/video), linked into the client on Linux; elsewhere
# it's the yap-video add-on (scripts/build/build-video.sh). FFmpeg isn't
# linked: it's opened at run time, from next to yap (the yap-video
# download for Linux is FFmpeg's libraries) or else the system's 8 or 9
# (src/video/src/ffmpeg.h), so only its headers are needed here, from
# the prebuilt FFmpeg scripts/build/fetch.sh fetches on x86_64 and
# pkg-config's elsewhere. Needs CMake and a C++20 compiler; capturing
# needs the headers scripts/build/build-video.sh lists, and a way whose headers
# are missing is left out. The client is C++ only here, so libstdc++ is
# linked statically (src/client/video/native.odin): yap then runs
# where the system's is older than the one it was built with.
if [ "$(uname -s)" = Linux ]; then
	lib=src/client/video/libyap_video.a
	if [ ! -f "$lib" ] || [ -n "$(find src/video/src src/video/include src/video/CMakeLists.txt scripts/build/ffmpeg.version -newer "$lib" | head -n 1)" ]; then
		echo "building $lib"
		ffmpeg_dir=
		if [ "$(uname -m)" = x86_64 ]; then
			ffmpeg_dir="-DFFMPEG_DIR=$PWD/$(sh scripts/build/fetch.sh ffmpeg .cache)"
		fi
		cmake -S src/video -B .cache/video-static -DCMAKE_BUILD_TYPE=Release -DYV_STATIC=ON \
			$ffmpeg_dir >/dev/null
		cmake --build .cache/video-static --target yap_video --parallel
		cp .cache/video-static/libyap_video.a "$lib"
	fi
	# The C++ compiler's own, which the library was built with.
	if [ ! -f src/client/video/libstdc++.a ] || [ "$lib" -nt src/client/video/libstdc++.a ]; then
		cp "$(${CXX:-c++} -print-file-name=libstdc++.a)" src/client/video/libstdc++.a
	fi
fi

# SQLite, for the server's database: one big C file, fetched on first
# use (scripts/build/fetch.sh) and compiled the way
# src/server/sqlite/yap_sqlite.c configures it. It takes a little while,
# and is only done again when that file or the version changes.
sqlite=src/server/sqlite
lib=$sqlite/libyap_sqlite.a
if [ ! -f "$lib" ] || [ "$sqlite/yap_sqlite.c" -nt "$lib" ] || [ scripts/build/sqlite.version -nt "$lib" ]; then
	. scripts/build/sqlite.version
	sh scripts/build/fetch.sh sqlite .cache
	echo "building $lib"
	${CC:-cc} -Os -I".cache/sqlite-autoconf-$sqlite_version" -c "$sqlite/yap_sqlite.c" -o "$sqlite/yap_sqlite.o"
	ar rcs "$lib" "$sqlite/yap_sqlite.o"
	rm "$sqlite/yap_sqlite.o"
fi

# libopus on macOS and OpenBSD: there's no prebuilt library for them in
# src/client/audio/opus, so it's built from the release source
# (scripts/build/fetch.sh, scripts/build/opus.version), the float API without DRED or OSCE, which is
# what src/client/audio/opus binds.
case "$(uname -s)" in
Darwin) opus_os=macos ;;
OpenBSD) opus_os=openbsd ;;
*) opus_os= ;;
esac
if [ -n "$opus_os" ] && [ ! -f "src/client/audio/opus/libopus_$opus_os.a" ]; then
	sh scripts/build/fetch.sh opus .cache
	echo "building src/client/audio/opus/libopus_$opus_os.a"
	. scripts/build/opus.version
	cmake -S ".cache/opus-$opus_version" -B ".cache/opus-$opus_os" \
		-DCMAKE_BUILD_TYPE=Release \
		-DOPUS_BUILD_PROGRAMS=OFF \
		-DOPUS_BUILD_TESTING=OFF \
		-DOPUS_INSTALL_PKG_CONFIG_MODULE=OFF \
		-DOPUS_INSTALL_CMAKE_CONFIG_MODULE=OFF >/dev/null
	# A job count, since OpenBSD's make won't take a bare -j.
	jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || getconf NPROCESSORS_ONLN)
	cmake --build ".cache/opus-$opus_os" --parallel "$jobs"
	cp ".cache/opus-$opus_os/libopus.a" "src/client/audio/opus/libopus_$opus_os.a"
fi

# libwebp, for WebP pictures, which the client and the server both link
# (src/common/webp).
sh scripts/build/build-webp.sh

# OpenBSD: two libraries Odin's own packages ask the linker for aren't
# there. vendor:stb only links its prebuilt vendor/stb/lib on Linux and
# macOS and wants system libraries anywhere else, so the ones the client
# and the server (GIF emoji) use are built here from Odin's copy of the
# source. And core:sys/posix links libdl, which OpenBSD doesn't have
# (dlopen is in libc), so an empty one stands in for it.
link_flags=
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
	link_flags="-extra-linker-flags:-L$bsd_libs"
fi

# The version and commit (src/common/version.odin); one word per define,
# so it's expanded unquoted.
version_defines=$(sh scripts/build/version-defines.sh)
. scripts/build/collections.sh
odin build src/server $collections -vet -strict-style -out:bin/yap-server $link_flags $version_defines "$@"
odin build src/client $collections -vet -strict-style -out:bin/yap $link_flags $version_defines "$@"
