#!/bin/sh
# Builds the web client into web/out/ (index.html, index.js,
# index.wasm): the client compiled by Odin to a wasm object, then linked
# by emscripten with the page's glue and the C it needs. Extra arguments
# go to the Odin build, e.g. ./web/build.sh -debug
#
# Needs emscripten (emcc) as well as Odin. Serve web/out/ over http and
# run bin/yap-relay beside it; see web/README.md.
set -e
cd "$(dirname "$0")/.."
out=web/out
mkdir -p "$out"

stb="$(odin root)/vendor/stb/src"

odin build client -target:wasi_wasm32 -build-mode:obj -no-entry-point -vet -strict-style -out:"$out/yap" "$@"

# -sSTACK_SIZE: the client keeps some large buffers on the stack (a state
# snapshot, a stored blob), and emscripten's default of 64 KiB is too
# small for them.
emcc "$out/yap.obj" \
	web/shell.c \
	web/audio_stub.c \
	client/miniaudio/yap_audio.c \
	"$stb/stb_truetype.c" \
	"$stb/stb_image.c" \
	-O2 \
	-sUSE_GLFW=3 \
	-sMIN_WEBGL_VERSION=2 -sMAX_WEBGL_VERSION=2 -sFULL_ES3 \
	-sALLOW_MEMORY_GROWTH \
	-sSTACK_SIZE=4MB \
	-sEXPORTED_FUNCTIONS=_main,_web_resize \
	--js-library web/wasi.js \
	--shell-file web/index.html \
	-o "$out/index.html"

echo "built $out/index.html"
