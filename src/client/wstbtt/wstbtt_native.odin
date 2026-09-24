#+build !wasi
/*
The font rasterizer, as ui_font.odin uses it.

A desktop build is vendor:stb/truetype as it is. vendor:stb supports
wasm too, but through its own libc shim, which wants threads the web
build doesn't have; under emscripten there is a real C library anyway,
so the web build compiles stb_truetype.c itself and binds the handful
of calls the font needs (see wstbtt_web.odin).

The client imports this package as `stbtt`, so the font code reads the
same either way.
*/
package wstbtt

import stbtt "vendor:stb/truetype"

fontinfo :: stbtt.fontinfo
pack_context :: stbtt.pack_context
packedchar :: stbtt.packedchar
pack_range :: stbtt.pack_range

InitFont :: stbtt.InitFont
FindGlyphIndex :: stbtt.FindGlyphIndex
ScaleForPixelHeight :: stbtt.ScaleForPixelHeight
GetFontVMetrics :: stbtt.GetFontVMetrics
GetCodepointHMetrics :: stbtt.GetCodepointHMetrics
PackBegin :: stbtt.PackBegin
PackEnd :: stbtt.PackEnd
PackFontRanges :: stbtt.PackFontRanges
