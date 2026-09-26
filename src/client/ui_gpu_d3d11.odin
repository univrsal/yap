#+build windows
package client

import log "../common/wlog"
import win32 "core:sys/windows"
import "vendor:directx/d3d11"
import "vendor:directx/dxgi"
import mu "vendor:microui"
import glfw "wglfw"

/*
The renderer's Direct3D 11 backend, for Windows. It does what the OpenGL
one does (ui_gpu_gl.odin), but costs far less: an OpenGL context brings
the whole of the graphics driver's OpenGL implementation into the
process, about 100 MB of it with AMD's, where Direct3D is part of
Windows and costs a tenth of that.

The device, like an OpenGL context, is made for one window and goes with
it (see window_open).
*/

Gpu :: struct {
	device:        ^d3d11.IDevice,
	ctx:           ^d3d11.IDeviceContext,
	swap_chain:    ^dxgi.ISwapChain1,
	target:        ^d3d11.IRenderTargetView, // the swap chain's back buffer
	width, height: i32, // of the back buffer
	vs:            ^d3d11.IVertexShader,
	ps:            [Texture_Kind]^d3d11.IPixelShader,
	sampler:       [Texture_Kind]^d3d11.ISamplerState,
	layout:        ^d3d11.IInputLayout,
	vbo:           ^d3d11.IBuffer,
	ebo:           ^d3d11.IBuffer,
	constants:     ^d3d11.IBuffer, // Constants
	blend:         ^d3d11.IBlendState,
	rasterizer:    ^d3d11.IRasterizerState,
	interval:      u32, // displays refreshes a present waits for
	drawn:         bool, // this frame has anything to present
	lost:          bool, // the device went away (see device_error)
}

// What Gpu_Texture points at.
@(private = "file")
D3D_Texture :: struct {
	texture: ^d3d11.ITexture2D,
	view:    ^d3d11.IShaderResourceView,
}

// The vertex shader's constant buffer, padded to the 16 bytes one takes.
@(private = "file")
Constants :: struct {
	screen: [2]f32,
	_:      [2]f32,
}

/*
The same shaders as the OpenGL backend's, in HLSL. The two kinds of
texture get a pixel shader each instead of a uniform to tell them apart.
*/
@(private = "file")
SHADERS :: `cbuffer Constants : register(b0) {
	float2 u_screen;
};
struct Vertex {
	float2 pos : POSITION;
	float2 uv : TEXCOORD0;
	float4 color : COLOR0;
};
struct Pixel {
	float4 pos : SV_Position;
	float2 uv : TEXCOORD0;
	float4 color : COLOR0;
};
Pixel vs(Vertex v) {
	Pixel p;
	p.pos = float4(v.pos.x / u_screen.x * 2.0 - 1.0, 1.0 - v.pos.y / u_screen.y * 2.0, 0.0, 1.0);
	p.uv = v.uv;
	p.color = v.color;
	return p;
}
Texture2D u_atlas : register(t0);
SamplerState u_sampler : register(s0);
// The atlases keep coverage in their red channel.
float4 ps_alpha(Pixel p) : SV_Target {
	return float4(p.color.rgb, p.color.a * u_atlas.Sample(u_sampler, p.uv).r);
}
// Chat images are ordinary colour textures.
float4 ps_rgba(Pixel p) : SV_Target {
	float4 t = u_atlas.Sample(u_sampler, p.uv);
	return float4(t.rgb * p.color.rgb, t.a * p.color.a);
}
`

// gpu_window_hints asks GLFW for a bare window: Direct3D brings its own
// swap chain.
gpu_window_hints :: proc() {
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
}

GPU_REQUIREMENT :: "Direct3D 10"

gpu_init :: proc(g: ^Gpu, window: glfw.WindowHandle) -> (ok: bool) {
	defer if !ok {
		gpu_destroy(g)
	}
	g.interval = 1

	/*
	Direct3D 10's hardware (feature level 10_0) has everything this
	needs. Without it (a virtual machine, say) Windows' own software
	renderer, WARP, still does, and a UI this simple barely notices.
	*/
	levels := [?]d3d11.FEATURE_LEVEL{._11_0, ._10_1, ._10_0}
	hr := d3d11.CreateDevice(
		nil,
		.HARDWARE,
		nil,
		{.SINGLETHREADED},
		&levels[0],
		len(levels),
		d3d11.SDK_VERSION,
		&g.device,
		nil,
		&g.ctx,
	)
	if failed(hr) {
		log.warnf("gpu: no Direct3D hardware device (0x%8x), drawing in software", u32(hr))
		hr = d3d11.CreateDevice(
			nil,
			.WARP,
			nil,
			{.SINGLETHREADED},
			&levels[0],
			len(levels),
			d3d11.SDK_VERSION,
			&g.device,
			nil,
			&g.ctx,
		)
		if failed(hr) {
			log.errorf("gpu: no Direct3D device at all (0x%8x)", u32(hr))
			return false
		}
	}

	make_swap_chain(g, glfw.GetWin32Window(window)) or_return
	make_pipeline(g) or_return
	return true
}

// make_swap_chain makes the window's swap chain, from the factory the
// device came from.
@(private = "file")
make_swap_chain :: proc(g: ^Gpu, hwnd: win32.HWND) -> bool {
	dxgi_device: ^dxgi.IDevice
	if failed(g.device->QueryInterface(dxgi.IDevice_UUID, (^rawptr)(&dxgi_device))) {
		log.error("gpu: the device isn't a DXGI device")
		return false
	}
	defer dxgi_device->Release()
	adapter: ^dxgi.IAdapter
	if failed(dxgi_device->GetAdapter(&adapter)) {
		log.error("gpu: the device has no adapter")
		return false
	}
	defer adapter->Release()
	factory: ^dxgi.IFactory2
	if failed(adapter->GetParent(dxgi.IFactory2_UUID, (^rawptr)(&factory))) {
		log.error("gpu: no DXGI 1.2 factory")
		return false
	}
	defer factory->Release()

	desc := dxgi.SWAP_CHAIN_DESC1 {
		Format      = .B8G8R8A8_UNORM,
		SampleDesc  = {Count = 1},
		BufferUsage = {.RENDER_TARGET_OUTPUT},
		BufferCount = 2,
		// While the window is being resized, and the back buffer isn't
		// yet, the last frame stays where it was rather than stretching.
		Scaling     = .NONE,
		SwapEffect  = .FLIP_DISCARD,
	}
	if hr := factory->CreateSwapChainForHwnd(g.device, hwnd, &desc, nil, nil, &g.swap_chain); failed(hr) {
		log.errorf("gpu: no swap chain (0x%8x)", u32(hr))
		return false
	}
	// Alt+Enter would have DXGI make the window exclusive fullscreen.
	factory->MakeWindowAssociation(hwnd, {.NO_ALT_ENTER})
	return true
}

/*
make_pipeline compiles the shaders and sets up everything they draw
with. The compiler is only loaded for as long as that takes: it's a few
megabytes that nothing else wants, and every Windows since 8.1 has it.
What it compiles comes back in blobs whose code is the compiler's, so it
stays loaded until the last of them is released (defers run backwards).
*/
@(private = "file")
make_pipeline :: proc(g: ^Gpu) -> bool {
	compiler := win32.LoadLibraryW(win32.L("d3dcompiler_47.dll"))
	if compiler == nil {
		log.error("gpu: d3dcompiler_47.dll is missing")
		return false
	}
	defer win32.FreeLibrary(compiler)
	compile := Compile(win32.GetProcAddress(compiler, "D3DCompile"))
	if compile == nil {
		log.error("gpu: d3dcompiler_47.dll has no D3DCompile")
		return false
	}
	vs_code := compile_shader(compile, "vs", "vs_4_0") or_return
	defer vs_code->Release()
	ps_alpha := compile_shader(compile, "ps_alpha", "ps_4_0") or_return
	defer ps_alpha->Release()
	ps_rgba := compile_shader(compile, "ps_rgba", "ps_4_0") or_return
	defer ps_rgba->Release()

	check(
		g.device->CreateVertexShader(vs_code->GetBufferPointer(), vs_code->GetBufferSize(), nil, &g.vs),
		"vertex shader",
	) or_return
	check(
		g.device->CreatePixelShader(ps_alpha->GetBufferPointer(), ps_alpha->GetBufferSize(), nil, &g.ps[.Alpha]),
		"pixel shader",
	) or_return
	check(
		g.device->CreatePixelShader(ps_rgba->GetBufferPointer(), ps_rgba->GetBufferSize(), nil, &g.ps[.Rgba]),
		"pixel shader",
	) or_return

	elements := [?]d3d11.INPUT_ELEMENT_DESC {
		{SemanticName = "POSITION", Format = .R32G32_FLOAT, AlignedByteOffset = u32(offset_of(Vertex, pos))},
		{SemanticName = "TEXCOORD", Format = .R32G32_FLOAT, AlignedByteOffset = u32(offset_of(Vertex, uv))},
		{SemanticName = "COLOR", Format = .R8G8B8A8_UNORM, AlignedByteOffset = u32(offset_of(Vertex, color))},
	}
	check(
		g.device->CreateInputLayout(
			&elements[0],
			len(elements),
			vs_code->GetBufferPointer(),
			vs_code->GetBufferSize(),
			&g.layout,
		),
		"input layout",
	) or_return

	vbo_desc := d3d11.BUFFER_DESC {
		ByteWidth      = MAX_QUADS * 4 * size_of(Vertex),
		Usage          = .DYNAMIC,
		BindFlags      = {.VERTEX_BUFFER},
		CPUAccessFlags = {.WRITE},
	}
	check(g.device->CreateBuffer(&vbo_desc, nil, &g.vbo), "vertex buffer") or_return

	indices := quad_indices()
	ebo_desc := d3d11.BUFFER_DESC {
		ByteWidth = size_of(indices^),
		Usage     = .IMMUTABLE,
		BindFlags = {.INDEX_BUFFER},
	}
	ebo_data := d3d11.SUBRESOURCE_DATA {
		pSysMem = indices,
	}
	check(g.device->CreateBuffer(&ebo_desc, &ebo_data, &g.ebo), "index buffer") or_return

	constants_desc := d3d11.BUFFER_DESC {
		ByteWidth      = size_of(Constants),
		Usage          = .DYNAMIC,
		BindFlags      = {.CONSTANT_BUFFER},
		CPUAccessFlags = {.WRITE},
	}
	check(g.device->CreateBuffer(&constants_desc, nil, &g.constants), "constant buffer") or_return

	// Glyphs are drawn 1:1 with physical pixels, so no filtering is
	// wanted; images are usually drawn smaller than they are.
	for filter, kind in ([Texture_Kind]d3d11.FILTER{.Alpha = .MIN_MAG_MIP_POINT, .Rgba = .MIN_MAG_MIP_LINEAR}) {
		sampler_desc := d3d11.SAMPLER_DESC {
			Filter         = filter,
			AddressU       = .CLAMP,
			AddressV       = .CLAMP,
			AddressW       = .CLAMP,
			ComparisonFunc = .NEVER,
			MaxLOD         = d3d11.FLOAT32_MAX,
		}
		check(g.device->CreateSamplerState(&sampler_desc, &g.sampler[kind]), "sampler") or_return
	}

	// Blended as glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA).
	blend_desc: d3d11.BLEND_DESC
	blend_desc.RenderTarget[0] = {
		BlendEnable           = true,
		SrcBlend              = .SRC_ALPHA,
		DestBlend             = .INV_SRC_ALPHA,
		BlendOp               = .ADD,
		SrcBlendAlpha         = .SRC_ALPHA,
		DestBlendAlpha        = .INV_SRC_ALPHA,
		BlendOpAlpha          = .ADD,
		RenderTargetWriteMask = u8(transmute(u32)d3d11.COLOR_WRITE_ENABLE_ALL),
	}
	check(g.device->CreateBlendState(&blend_desc, &g.blend), "blend state") or_return

	rasterizer_desc := d3d11.RASTERIZER_DESC {
		FillMode        = .SOLID,
		CullMode        = .NONE,
		DepthClipEnable = true,
		ScissorEnable   = true,
	}
	check(g.device->CreateRasterizerState(&rasterizer_desc, &g.rasterizer), "rasterizer state") or_return
	return true
}

// D3DCompile, from d3dcompiler_47.dll.
@(private = "file")
Compile :: #type proc "system" (
	src: rawptr,
	size: uint,
	name: cstring,
	defines: rawptr,
	include: rawptr,
	entry: cstring,
	target: cstring,
	flags1: u32,
	flags2: u32,
	code: ^^d3d11.IBlob,
	errors: ^^d3d11.IBlob,
) -> win32.HRESULT

// compile_shader compiles one entry point of SHADERS.
@(private = "file")
compile_shader :: proc(compile: Compile, entry, target: cstring) -> (code: ^d3d11.IBlob, ok: bool) {
	OPTIMIZATION_LEVEL3 :: 1 << 15
	errors: ^d3d11.IBlob
	src := SHADERS
	hr := compile(raw_data(src), len(src), "yap", nil, nil, entry, target, OPTIMIZATION_LEVEL3, 0, &code, &errors)
	if errors != nil {
		log.errorf("gpu: %s: %s", entry, cstring(errors->GetBufferPointer()))
		errors->Release()
	}
	if failed(hr) {
		return nil, false
	}
	return code, true
}

gpu_destroy :: proc(g: ^Gpu) {
	release(&g.rasterizer)
	release(&g.blend)
	for &s in g.sampler {
		release(&s)
	}
	release(&g.constants)
	release(&g.ebo)
	release(&g.vbo)
	release(&g.layout)
	for &ps in g.ps {
		release(&ps)
	}
	release(&g.vs)
	release(&g.target)
	release(&g.swap_chain)
	if g.ctx != nil {
		g.ctx->ClearState()
	}
	release(&g.ctx)
	release(&g.device)
	g^ = {}
}

// gpu_lost is whether the device has gone and has to be set up again
// (renderer_reset): the driver was updated or reset, or setting it up
// again didn't work either.
gpu_lost :: proc(g: ^Gpu) -> bool {
	return g.lost || g.device == nil
}

// gpu_swap_interval says how many display refreshes a present waits
// for: 1 for vsync, 0 not to wait (see set_swap_pace).
gpu_swap_interval :: proc(g: ^Gpu, interval: i32) {
	g.interval = u32(interval)
}

// gpu_begin starts a frame, cleared to `clear`, projecting view_w x
// view_h logical pixels onto the fb_w x fb_h framebuffer. False when
// there's nothing to draw into.
gpu_begin :: proc(g: ^Gpu, fb_w, fb_h: i32, view_w, view_h: f32, clear: mu.Color) -> bool {
	g.drawn = false
	// Minimized, the window has no size, and nor can a back buffer.
	if gpu_lost(g) || fb_w <= 0 || fb_h <= 0 {
		return false
	}
	if g.target == nil || fb_w != g.width || fb_h != g.height {
		resize(g, fb_w, fb_h) or_return
	}
	g.drawn = true

	c := [4]f32{f32(clear.r) / 255, f32(clear.g) / 255, f32(clear.b) / 255, 1}
	g.ctx->ClearRenderTargetView(g.target, &c)

	mapped: d3d11.MAPPED_SUBRESOURCE
	if succeeded(g.ctx->Map(g.constants, 0, .WRITE_DISCARD, {}, &mapped)) {
		(^Constants)(mapped.pData)^ = {screen = {view_w, view_h}}
		g.ctx->Unmap(g.constants, 0)
	}

	viewport := d3d11.VIEWPORT {
		Width    = f32(fb_w),
		Height   = f32(fb_h),
		MaxDepth = 1,
	}
	stride := u32(size_of(Vertex))
	offset := u32(0)
	g.ctx->OMSetRenderTargets(1, &g.target, nil)
	g.ctx->OMSetBlendState(g.blend, nil, 0xffffffff)
	g.ctx->RSSetViewports(1, &viewport)
	g.ctx->RSSetState(g.rasterizer)
	g.ctx->IASetInputLayout(g.layout)
	g.ctx->IASetPrimitiveTopology(.TRIANGLELIST)
	g.ctx->IASetVertexBuffers(0, 1, &g.vbo, &stride, &offset)
	g.ctx->IASetIndexBuffer(g.ebo, .R16_UINT, 0)
	g.ctx->VSSetShader(g.vs, nil, 0)
	g.ctx->VSSetConstantBuffers(0, 1, &g.constants)
	gpu_clip(g, 0, 0, fb_w, fb_h)
	return true
}

// resize makes the back buffer fb_w x fb_h, which it has to be for
// drawing to land 1:1 on the window's pixels.
@(private = "file")
resize :: proc(g: ^Gpu, fb_w, fb_h: i32) -> bool {
	// Nothing may hold on to the old back buffer while it's resized.
	g.ctx->OMSetRenderTargets(0, nil, nil)
	release(&g.target)
	if hr := g.swap_chain->ResizeBuffers(0, u32(fb_w), u32(fb_h), .UNKNOWN, {}); failed(hr) {
		device_error(g, "resizing the swap chain", hr)
		return false
	}
	back: ^d3d11.ITexture2D
	if hr := g.swap_chain->GetBuffer(0, d3d11.ITexture2D_UUID, (^rawptr)(&back)); failed(hr) {
		device_error(g, "getting the back buffer", hr)
		return false
	}
	defer back->Release()
	if hr := g.device->CreateRenderTargetView(back, nil, &g.target); failed(hr) {
		device_error(g, "making the render target", hr)
		return false
	}
	g.width, g.height = fb_w, fb_h
	return true
}

gpu_end :: proc(g: ^Gpu) {}

gpu_present :: proc(g: ^Gpu) {
	if !g.drawn {
		return
	}
	// Occluded (DXGI_STATUS_OCCLUDED) isn't a failure: the window is
	// just out of sight.
	if hr := g.swap_chain->Present(g.interval, {}); failed(hr) {
		device_error(g, "presenting", hr)
	}
}

// gpu_clip limits drawing to a rect of physical pixels, counted from
// the top left.
gpu_clip :: proc(g: ^Gpu, x, y, w, h: i32) {
	rect := d3d11.RECT{x, y, x + w, y + h}
	g.ctx->RSSetScissorRects(1, &rect)
}

// gpu_draw draws quads (four vertices each, see quad_indices) from `tex`.
gpu_draw :: proc(g: ^Gpu, vertices: []Vertex, tex: Gpu_Texture, kind: Texture_Kind) {
	t := (^D3D_Texture)(tex)
	if t == nil {
		return
	}
	mapped: d3d11.MAPPED_SUBRESOURCE
	if failed(g.ctx->Map(g.vbo, 0, .WRITE_DISCARD, {}, &mapped)) {
		return
	}
	copy(([^]Vertex)(mapped.pData)[:len(vertices)], vertices)
	g.ctx->Unmap(g.vbo, 0)

	g.ctx->PSSetShader(g.ps[kind], nil, 0)
	g.ctx->PSSetSamplers(0, 1, &g.sampler[kind])
	g.ctx->PSSetShaderResources(0, 1, &t.view)
	g.ctx->DrawIndexed(u32(len(vertices) / 4 * 6), 0, 0)
}

/*
gpu_texture_make makes a width x height texture from `pixels` (one byte
a pixel for .Alpha, four for .Rgba). A texture without pixels is none at
all: only the page's video decoder fills one of those (video_web.odin),
and there's no page here.
*/
gpu_texture_make :: proc(g: ^Gpu, kind: Texture_Kind, width, height: i32, pixels: []u8) -> Gpu_Texture {
	if pixels == nil || width <= 0 || height <= 0 || g.device == nil {
		return 0
	}
	pixel_size: u32 = 1 if kind == .Alpha else 4
	desc := d3d11.TEXTURE2D_DESC {
		Width      = u32(width),
		Height     = u32(height),
		MipLevels  = 1,
		ArraySize  = 1,
		Format     = .R8_UNORM if kind == .Alpha else .R8G8B8A8_UNORM,
		SampleDesc = {Count = 1},
		Usage      = .DEFAULT,
		BindFlags  = {.SHADER_RESOURCE},
	}
	data := d3d11.SUBRESOURCE_DATA {
		pSysMem     = raw_data(pixels),
		SysMemPitch = u32(width) * pixel_size,
	}
	t := new(D3D_Texture)
	if hr := g.device->CreateTexture2D(&desc, &data, &t.texture); failed(hr) {
		log.errorf("gpu: no %dx%d texture (0x%8x)", width, height, u32(hr))
		free(t)
		return 0
	}
	if hr := g.device->CreateShaderResourceView(t.texture, nil, &t.view); failed(hr) {
		log.errorf("gpu: no texture view (0x%8x)", u32(hr))
		t.texture->Release()
		free(t)
		return 0
	}
	return Gpu_Texture(uintptr(t))
}

// gpu_texture_update_rows replaces rows y0 up to y1 of an .Alpha texture
// that is `width` wide with `rows`.
gpu_texture_update_rows :: proc(g: ^Gpu, tex: Gpu_Texture, width, y0, y1: i32, rows: []u8) {
	t := (^D3D_Texture)(tex)
	if t == nil {
		return
	}
	box := d3d11.BOX {
		left   = 0,
		top    = u32(y0),
		front  = 0,
		right  = u32(width),
		bottom = u32(y1),
		back   = 1,
	}
	g.ctx->UpdateSubresource(t.texture, 0, &box, raw_data(rows), u32(width), 0)
}

// gpu_texture_delete deletes `tex`, if there is one, and makes it 0.
gpu_texture_delete :: proc(g: ^Gpu, tex: ^Gpu_Texture) {
	if t := (^D3D_Texture)(tex^); t != nil {
		release(&t.view)
		release(&t.texture)
		free(t)
	}
	tex^ = 0
}

// device_error says what went wrong. Losing the device (the driver was
// updated or reset) is only said once, and ui_frame sets it up again.
@(private = "file")
device_error :: proc(g: ^Gpu, doing: string, hr: win32.HRESULT) {
	if hr == dxgi.ERROR_DEVICE_REMOVED || hr == dxgi.ERROR_DEVICE_RESET {
		if !g.lost {
			reason := g.device->GetDeviceRemovedReason()
			log.errorf("gpu: the Direct3D device is gone (0x%8x) %s", u32(reason), doing)
		}
		g.lost = true
		return
	}
	log.errorf("gpu: %s failed (0x%8x)", doing, u32(hr))
}

@(private = "file")
check :: proc(hr: win32.HRESULT, what: string) -> bool {
	if failed(hr) {
		log.errorf("gpu: no %s (0x%8x)", what, u32(hr))
		return false
	}
	return true
}

@(private = "file")
failed :: #force_inline proc "contextless" (hr: win32.HRESULT) -> bool {
	return hr < 0
}

@(private = "file")
succeeded :: #force_inline proc "contextless" (hr: win32.HRESULT) -> bool {
	return hr >= 0
}

// release releases a COM object, if there is one, and forgets it.
@(private = "file")
release :: proc(p: ^^$T) {
	if p^ != nil {
		p^->Release()
		p^ = nil
	}
}
