#+build !wasi
// The image decoder, as used by clipboard.decode.
//
// A desktop build uses vendor:stb/image unchanged. As with stb_truetype (see
// wstbtt), the vendor wasm build needs a libc shim with threads, so the web
// build compiles stb_image.c itself and binds the few calls that decoding
// needs (see wstbi_web.odin).
//
// The clipboard package imports this as `stbi`, so the decoding code is the
// same on both.
package wstbi

import stbi "vendor:stb/image"

info_from_memory :: stbi.info_from_memory
load_from_memory :: stbi.load_from_memory
// Decodes every frame of a GIF, and each frame's delay in milliseconds (both
// are freed with image_free). Native only: the web client leaves GIFs to the
// page.
load_gif_from_memory :: stbi.load_gif_from_memory
image_free :: stbi.image_free
failure_reason :: stbi.failure_reason
