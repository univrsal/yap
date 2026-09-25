#!/bin/sh
# Builds the web client into web/out/ (index.html, index.js,
# index.wasm, favicon.ico): the client compiled by Odin to a wasm object, then linked
# by emscripten with the page's glue and the C it needs. Extra arguments
# go to the Odin build, e.g. ./web/build.sh -debug
#
# Needs emscripten (emcc) as well as Odin, and the first time also curl
# and CMake, to fetch and build libopus for wasm (below). To use it, build
# the server and run bin/yap-server with the relay on; see web/README.md.
set -e
cd "$(dirname "$0")/.."
out=web/out
mkdir -p "$out"

stb="$(odin root)/vendor/stb/src"

# libopus, built for wasm. The desktop builds link the prebuilt libraries
# in client/opus; there's none for wasm, and the source is too big to keep
# in the repo (its DNN model data), so the release client/opus is bound
# against is fetched once, checked and built into web/deps/ (gitignored).
# Delete web/deps/ to build it again.
opus_version=1.6
deps=web/deps
opus_build=$deps/opus-$opus_version-wasm
opus_lib=$opus_build/libopus.a
if [ ! -f "$opus_lib" ]; then
	scripts/fetch-opus.sh "$deps"
	rm -rf "$opus_build"
	echo "building $opus_lib"
	# The float API without DRED or OSCE (both off by default), which is
	# what client/opus binds. Hardening only adds _FORTIFY_SOURCE and stack
	# protectors, neither of which means anything on wasm.
	emcmake cmake -S "$deps/opus-$opus_version" -B "$opus_build" \
		-DCMAKE_BUILD_TYPE=Release \
		-DOPUS_BUILD_PROGRAMS=OFF \
		-DOPUS_BUILD_TESTING=OFF \
		-DOPUS_HARDENING=OFF \
		-DOPUS_INSTALL_PKG_CONFIG_MODULE=OFF \
		-DOPUS_INSTALL_CMAKE_CONFIG_MODULE=OFF >/dev/null
	cmake --build "$opus_build" --parallel
fi

# What web/touch.js calls (src/client/ui_touch_web.odin).
touch_exports=_web_touch_tap,_web_text_box_at,_web_touch_drag_begin,_web_touch_drag_move,_web_touch_drag_end,_web_touch_scroll,_web_text_rune,_web_text_backspace,_web_text_enter
# What web/background.js calls (src/client/main_web.odin).
background_exports=_web_tick
# What web/paste.js calls (src/client/ui_paste_web.odin), and the heap helpers it uses.
paste_exports=_web_paste_image,_web_paste_failed,_malloc,_free

# The version and commit (src/common/version.odin); one word per define,
# so it's expanded unquoted.
version_defines=$(scripts/version-defines.sh)

# -o:speed, always: at Odin's default optimization level Safari's web
# process crashes a few seconds into a call. Its optimizing wasm compiler
# (OMG, on B3) runs out of memory tiering up strings.index once that gets
# hot - seen in WebKitGTK 2.52 and iOS 26.6, reproduced only inside this
# module - and the page dies without a word in the console. The code
# -o:speed gives it compiles fine.
odin build src/client -target:wasi_wasm32 -build-mode:obj -no-entry-point -vet -strict-style -o:speed -out:"$out/yap" $version_defines "$@"

# -sSTACK_SIZE: the client keeps some large buffers on the stack (a state
# snapshot, a stored blob), and emscripten's default of 64 KiB is too
# small for them.
emcc "$out/yap.obj" \
	web/shell.c \
	src/client/miniaudio/yap_audio.c \
	src/client/rnn/yap_rnn.c \
	"$opus_lib" \
	"$stb/stb_truetype.c" \
	"$stb/stb_image.c" \
	-O2 \
	-sUSE_GLFW=3 \
	-sMIN_WEBGL_VERSION=2 -sMAX_WEBGL_VERSION=2 -sFULL_ES3 \
	-sALLOW_MEMORY_GROWTH \
	-sSTACK_SIZE=4MB \
	-sEXPORTED_FUNCTIONS=_main,_web_resize,$touch_exports,$background_exports,$paste_exports \
	--js-library web/wasi.js \
	--pre-js web/touch.js \
	--pre-js web/background.js \
	--pre-js web/paste.js \
	--pre-js web/video.js \
	--shell-file web/index.html \
	-o "$out/index.html"

# The tab's icon, the same one the desktop programs have.
cp src/client/assets/icon.ico "$out/favicon.ico"

echo "built $out/index.html"
