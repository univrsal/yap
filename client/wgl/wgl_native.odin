#+build !wasi
/*
OpenGL, as the renderer uses it.

A desktop build loads OpenGL 3.3 through vendor:OpenGL. A web build
draws with WebGL 2 through emscripten, where the entry points are linked
in like any other C library and there is nothing to load at all - and
where vendor:OpenGL can't be used anyway, since it reaches for core:os,
which wasm has none of.

The client imports this package as `gl`, so the drawing code reads the
same either way. Only what the renderer uses is here.
*/
package wgl

import gl "vendor:OpenGL"

ActiveTexture :: gl.ActiveTexture
BindBuffer :: gl.BindBuffer
BindTexture :: gl.BindTexture
BindVertexArray :: gl.BindVertexArray
BlendFunc :: gl.BlendFunc
BufferData :: gl.BufferData
BufferSubData :: gl.BufferSubData
Clear :: gl.Clear
ClearColor :: gl.ClearColor
DeleteBuffers :: gl.DeleteBuffers
DeleteProgram :: gl.DeleteProgram
DeleteTextures :: gl.DeleteTextures
DeleteVertexArrays :: gl.DeleteVertexArrays
Disable :: gl.Disable
DrawElements :: gl.DrawElements
Enable :: gl.Enable
EnableVertexAttribArray :: gl.EnableVertexAttribArray
GenBuffers :: gl.GenBuffers
GenTextures :: gl.GenTextures
GenVertexArrays :: gl.GenVertexArrays
GetUniformLocation :: gl.GetUniformLocation
PixelStorei :: gl.PixelStorei
Scissor :: gl.Scissor
TexImage2D :: gl.TexImage2D
TexParameteri :: gl.TexParameteri
Uniform1i :: gl.Uniform1i
Uniform2f :: gl.Uniform2f
UseProgram :: gl.UseProgram
VertexAttribPointer :: gl.VertexAttribPointer
Viewport :: gl.Viewport

ARRAY_BUFFER :: gl.ARRAY_BUFFER
BLEND :: gl.BLEND
CLAMP_TO_EDGE :: gl.CLAMP_TO_EDGE
COLOR_BUFFER_BIT :: gl.COLOR_BUFFER_BIT
DYNAMIC_DRAW :: gl.DYNAMIC_DRAW
ELEMENT_ARRAY_BUFFER :: gl.ELEMENT_ARRAY_BUFFER
FLOAT :: gl.FLOAT
LINEAR :: gl.LINEAR
NEAREST :: gl.NEAREST
ONE_MINUS_SRC_ALPHA :: gl.ONE_MINUS_SRC_ALPHA
R8 :: gl.R8
RED :: gl.RED
RGBA :: gl.RGBA
RGBA8 :: gl.RGBA8
SCISSOR_TEST :: gl.SCISSOR_TEST
SRC_ALPHA :: gl.SRC_ALPHA
STATIC_DRAW :: gl.STATIC_DRAW
TEXTURE0 :: gl.TEXTURE0
TEXTURE_2D :: gl.TEXTURE_2D
TEXTURE_MAG_FILTER :: gl.TEXTURE_MAG_FILTER
TEXTURE_MIN_FILTER :: gl.TEXTURE_MIN_FILTER
TEXTURE_WRAP_S :: gl.TEXTURE_WRAP_S
TEXTURE_WRAP_T :: gl.TEXTURE_WRAP_T
TRIANGLES :: gl.TRIANGLES
UNPACK_ALIGNMENT :: gl.UNPACK_ALIGNMENT
UNSIGNED_BYTE :: gl.UNSIGNED_BYTE
UNSIGNED_SHORT :: gl.UNSIGNED_SHORT

// The desktop's function pointers have to be fetched once the context
// is current; see wgl_web.odin for why the web build has nothing to do.
load_up_to :: gl.load_up_to
load_shaders_source :: gl.load_shaders_source
