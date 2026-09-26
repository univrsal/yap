#+build wasi
/*
The web half of the drawing layer: WebGL 2 through emscripten, whose
entry points are ordinary C symbols. The renderer only asks for a small
corner of OpenGL, and all of it exists in WebGL 2 - the one thing
missing is vendor:OpenGL's shader helper, which is written out here.
*/
package wgl

@(default_calling_convention = "c", link_prefix = "gl")
foreign _ {
	ActiveTexture :: proc(texture: u32) ---
	BindBuffer :: proc(target: u32, buffer: u32) ---
	BindTexture :: proc(target: u32, texture: u32) ---
	BindVertexArray :: proc(array: u32) ---
	BlendFunc :: proc(sfactor, dfactor: u32) ---
	BufferData :: proc(target: u32, size: int, data: rawptr, usage: u32) ---
	BufferSubData :: proc(target: u32, offset: uintptr, size: int, data: rawptr) ---
	Clear :: proc(mask: u32) ---
	ClearColor :: proc(r, g, b, a: f32) ---
	DeleteBuffers :: proc(n: i32, buffers: [^]u32) ---
	DeleteProgram :: proc(program: u32) ---
	DeleteTextures :: proc(n: i32, textures: [^]u32) ---
	DeleteVertexArrays :: proc(n: i32, arrays: [^]u32) ---
	Disable :: proc(cap: u32) ---
	DrawElements :: proc(mode: u32, count: i32, type: u32, indices: rawptr) ---
	Enable :: proc(cap: u32) ---
	EnableVertexAttribArray :: proc(index: u32) ---
	GenBuffers :: proc(n: i32, buffers: [^]u32) ---
	GenTextures :: proc(n: i32, textures: [^]u32) ---
	GenVertexArrays :: proc(n: i32, arrays: [^]u32) ---
	GetUniformLocation :: proc(program: u32, name: cstring) -> i32 ---
	PixelStorei :: proc(pname: u32, param: i32) ---
	Scissor :: proc(x, y, width, height: i32) ---
	TexImage2D :: proc(target: u32, level, internalformat, width, height, border: i32, format, type: u32, pixels: rawptr) ---
	TexParameteri :: proc(target, pname: u32, param: i32) ---
	TexSubImage2D :: proc(target: u32, level, xoffset, yoffset, width, height: i32, format, type: u32, pixels: rawptr) ---
	Uniform1i :: proc(location: i32, v0: i32) ---
	Uniform2f :: proc(location: i32, v0, v1: f32) ---
	UseProgram :: proc(program: u32) ---
	VertexAttribPointer :: proc(index: u32, size: i32, type: u32, normalized: bool, stride: i32, pointer: uintptr) ---
	Viewport :: proc(x, y, width, height: i32) ---

	// Only the shader helper below needs these.
	CreateShader :: proc(type: u32) -> u32 ---
	ShaderSource :: proc(shader: u32, count: i32, strings: [^]cstring, lengths: [^]i32) ---
	CompileShader :: proc(shader: u32) ---
	GetShaderiv :: proc(shader: u32, pname: u32, params: ^i32) ---
	GetShaderInfoLog :: proc(shader: u32, maxLength: i32, length: ^i32, infoLog: [^]u8) ---
	DeleteShader :: proc(shader: u32) ---
	CreateProgram :: proc() -> u32 ---
	AttachShader :: proc(program, shader: u32) ---
	LinkProgram :: proc(program: u32) ---
	GetProgramiv :: proc(program: u32, pname: u32, params: ^i32) ---
	GetProgramInfoLog :: proc(program: u32, maxLength: i32, length: ^i32, infoLog: [^]u8) ---
}

ARRAY_BUFFER :: 0x8892
BLEND :: 0x0BE2
CLAMP_TO_EDGE :: 0x812F
COLOR_BUFFER_BIT :: 0x00004000
DYNAMIC_DRAW :: 0x88E8
ELEMENT_ARRAY_BUFFER :: 0x8893
FLOAT :: 0x1406
LINEAR :: 0x2601
NEAREST :: 0x2600
ONE_MINUS_SRC_ALPHA :: 0x0303
R8 :: 0x8229
RED :: 0x1903
RGBA :: 0x1908
RGBA8 :: 0x8058
SCISSOR_TEST :: 0x0C11
SRC_ALPHA :: 0x0302
STATIC_DRAW :: 0x88E4
TEXTURE0 :: 0x84C0
TEXTURE_2D :: 0x0DE1
TEXTURE_MAG_FILTER :: 0x2800
TEXTURE_MIN_FILTER :: 0x2801
TEXTURE_WRAP_S :: 0x2802
TEXTURE_WRAP_T :: 0x2803
TRIANGLES :: 0x0004
UNPACK_ALIGNMENT :: 0x0CF5
UNSIGNED_BYTE :: 0x1401
UNSIGNED_SHORT :: 0x1403

@(private)
VERTEX_SHADER :: 0x8B31
@(private)
FRAGMENT_SHADER :: 0x8B30
@(private)
COMPILE_STATUS :: 0x8B81
@(private)
LINK_STATUS :: 0x8B82

// WebGL is there as soon as the canvas has a context, so there is
// nothing to load.
load_up_to :: proc(major, minor: int, set_proc_address: proc(p: rawptr, name: cstring)) {}

/*
load_shaders_source compiles and links one shader pair, the way
vendor:OpenGL's helper of the same name does. Whatever the driver has
to say about a shader that won't compile is printed, since in a browser
that message is the only way to find out.
*/
load_shaders_source :: proc(vertex, fragment: string) -> (program: u32, ok: bool) {
	vs := compile(VERTEX_SHADER, vertex) or_return
	defer DeleteShader(vs)
	fs := compile(FRAGMENT_SHADER, fragment) or_return
	defer DeleteShader(fs)

	program = CreateProgram()
	AttachShader(program, vs)
	AttachShader(program, fs)
	LinkProgram(program)
	status: i32
	GetProgramiv(program, LINK_STATUS, &status)
	if status == 0 {
		log: [1024]u8
		GetProgramInfoLog(program, len(log), nil, &log[0])
		print_line("shader link failed: ", string(cstring(&log[0])))
		DeleteProgram(program)
		return 0, false
	}
	return program, true
}

@(private)
compile :: proc(type: u32, source: string) -> (shader: u32, ok: bool) {
	shader = CreateShader(type)
	text := cstring(raw_data(source)) // the sources are literals, so NUL-terminated
	length := i32(len(source))
	ShaderSource(shader, 1, &text, &length)
	CompileShader(shader)
	status: i32
	GetShaderiv(shader, COMPILE_STATUS, &status)
	if status == 0 {
		log: [1024]u8
		GetShaderInfoLog(shader, len(log), nil, &log[0])
		print_line("shader compile failed: ", string(cstring(&log[0])))
		DeleteShader(shader)
		return 0, false
	}
	return shader, true
}

@(private)
foreign _ {
	emscripten_console_error :: proc "c" (text: cstring) ---
}

@(private)
print_line :: proc(prefix, text: string) {
	buf: [1200]u8
	n := copy(buf[:], prefix)
	n += copy(buf[n:len(buf) - 1], text)
	buf[n] = 0
	emscripten_console_error(cstring(&buf[0]))
}
