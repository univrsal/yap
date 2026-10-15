#+build !wasi
// The font rasterizer, as used by render/font.odin.
//
// A desktop build uses vendor:stb/truetype unchanged. vendor:stb supports wasm
// too, but through its own libc shim, which needs threads that the web build
// doesn't have. Under emscripten there is a real C library anyway, so the web
// build compiles stb_truetype.c itself and binds the handful of calls that the
// font code needs (see wstbtt_web.odin).
//
// The client imports this package as `stbtt`, so the font code is the same on
// both.
package wstbtt

import stbtt "vendor:stb/truetype"

fontinfo :: stbtt.fontinfo
pack_context :: stbtt.pack_context
packedchar :: stbtt.packedchar
pack_range :: stbtt.pack_range

InitFont :: stbtt.InitFont
FindGlyphIndex :: stbtt.FindGlyphIndex
ScaleForPixelHeight :: stbtt.ScaleForPixelHeight
ScaleForMappingEmToPixels :: stbtt.ScaleForMappingEmToPixels
GetFontVMetrics :: stbtt.GetFontVMetrics
GetCodepointHMetrics :: stbtt.GetCodepointHMetrics
PackBegin :: stbtt.PackBegin
PackEnd :: stbtt.PackEnd
PackFontRanges :: stbtt.PackFontRanges
GetCodepointBitmapBox :: stbtt.GetCodepointBitmapBox
MakeCodepointBitmap :: stbtt.MakeCodepointBitmap
