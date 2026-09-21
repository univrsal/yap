#+build !wasi
/*
The image decoder, as clipboard.decode uses it.

A desktop build is vendor:stb/image as it is. Like stb_truetype (see
wstbtt), the vendor wasm build wants a libc shim with threads, so the
web build compiles stb_image.c itself and binds the few calls decoding
needs (see wstbi_web.odin).

The clipboard package imports this as `stbi`, so the decoding code
reads the same either way.
*/
package wstbi

import stbi "vendor:stb/image"

info_from_memory :: stbi.info_from_memory
load_from_memory :: stbi.load_from_memory
image_free :: stbi.image_free
failure_reason :: stbi.failure_reason
