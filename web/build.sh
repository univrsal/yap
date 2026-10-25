#!/bin/sh
# Builds the web client into web/out/ (index.html, index.js,
# index.wasm, favicon.ico and what installing it as an app needs): the client compiled by Odin to a wasm object, then linked
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

# libopus, built for wasm. The source is too big to keep in the repo (its
# DNN model data), so the release client/audio/opus is bound against
# (scripts/build/opus.version) is fetched once, checked and built into
# web/deps/ (gitignored). Delete web/deps/ to build it again.
. scripts/build/opus.version
deps=web/deps
opus_build=$deps/opus-$opus_version-wasm
opus_lib=$opus_build/libopus.a
if [ ! -f "$opus_lib" ]; then
	sh scripts/build/fetch-opus.sh "$deps"
	rm -rf "$opus_build"
	echo "building $opus_lib"
	# The float API without DRED or OSCE (both off by default), which is
	# what client/audio/opus binds. Hardening only adds _FORTIFY_SOURCE and stack
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
touch_exports=_web_touch_tap,_web_touch_hold,_web_text_box_at,_web_touch_drag_begin,_web_touch_drag_move,_web_touch_drag_end,_web_touch_scroll,_web_text_rune,_web_text_backspace,_web_text_enter
# What web/field.js calls (src/client/ui_field_web.odin).
field_exports=_web_field_input,_web_field_focus,_web_field_lines,_web_field_touched
# What web/background.js calls (src/client/main_web.odin).
background_exports=_web_tick,_web_visibility
# What web/paste.js calls (src/client/ui_paste_web.odin), and the heap helpers it uses.
paste_exports=_web_file_pasted,_web_paste_failed,_web_paste_text,_web_max_attachment,_malloc,_free
# What web/files.js calls (src/client/ui_files_web.odin).
files_exports=_web_file_picked,_web_file_dropped,_web_drag
# What web/avatar.js calls (src/client/ui_avatar_pick_web.odin).
avatar_exports=_web_avatar_reading,_web_avatar_picked,_web_avatar_failed
# What web/decode.js calls (src/client/ui_images_worker_web.odin).
decode_exports=_web_image_decoded
# What web/sounds.js calls (src/client/ui_sounds_web.odin).
sounds_exports=_web_sound_picked,_web_sound_failed,_web_sound_loaded,_web_sound_missing

# The version and commit (src/common/version.odin); one word per define,
# so it's expanded unquoted.
version_defines=$(sh scripts/build/version-defines.sh)

# We seem to need -o:speed to prevent iOS safari from crashing, but it can increase build times quite a bit
# The object's name is spelled out: without an extension Odin picks one,
# and newer versions pick .wasm rather than .obj, which left emcc below
# linking a stale yap.obj.
. scripts/build/collections.sh
odin build src/client $collections -o:speed -target:wasi_wasm32 -build-mode:obj -no-entry-point -vet -strict-style -out:"$out/yap.obj" $version_defines "$@"

# -sSTACK_SIZE: the client keeps some large buffers on the stack (a state
# snapshot, a stored blob), and emscripten's default of 64 KiB is too
# small for them.
emcc "$out/yap.obj" \
	web/shell.c \
	src/client/audio/miniaudio/yap_audio.c \
	src/client/audio/rnn/yap_rnn.c \
	"$opus_lib" \
	"$stb/stb_truetype.c" \
	"$stb/stb_image.c" \
	-O1 \
	-sUSE_GLFW=3 \
	-sMIN_WEBGL_VERSION=2 -sMAX_WEBGL_VERSION=2 -sFULL_ES3 \
	-sALLOW_MEMORY_GROWTH \
	-sSTACK_SIZE=4MB \
	-sEXPORTED_FUNCTIONS=_main,_web_resize,$touch_exports,$field_exports,$background_exports,$paste_exports,$files_exports,$avatar_exports,$decode_exports,$sounds_exports \
	--js-library web/wasi.js \
	--pre-js web/touch.js \
	--pre-js web/field.js \
	--pre-js web/background.js \
	--pre-js web/paste.js \
	--pre-js web/files.js \
	--pre-js web/avatar.js \
	--pre-js web/keys.js \
	--pre-js web/images.js \
	--pre-js web/decode.js \
	--pre-js web/sounds.js \
	--pre-js web/video.js \
	--pre-js web/push.js \
	--shell-file web/index.html \
	-o "$out/index.html"

# The tab's icon, the same one the desktop programs have.
cp src/client/assets/icon.ico "$out/favicon.ico"
# The manifest and icons for installing it as an app (index.html).
cp web/manifest.webmanifest web/sw.js web/icon-192.png web/icon-512.png web/apple-touch-icon.png "$out/"

echo "built $out/index.html"
