#+build darwin
package render

import "base:intrinsics"
import glfw "client:wglfw"
import log "common:wlog"
import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"
import CA "vendor:darwin/QuartzCore"
import mu "vendor:microui"

// The renderer's Metal backend, used on macOS. It does the same as the OpenGL
// backend (gpu_gl.odin) at a lower cost. Apple's OpenGL is a layer on top of
// Metal that costs about 18 MB of its own and also keeps a second copy of
// every texture.
//
// The window's view gets a CAMetalLayer, whose drawables are the frames. At
// most one frame is on the GPU at a time. The next frame waits for it before
// writing into the vertex buffer or into a texture that the GPU might still be
// reading (settle), which costs almost nothing for a UI this simple. Within a
// frame, draws only ever append to the vertex buffer, because the GPU reads it
// later, once the frame is committed (gpu_present).
//
// Like an OpenGL context, the device is created for one window and is
// destroyed together with it (see window_open).

Gpu :: struct {
	window:        glfw.WindowHandle,
	device:        ^MTL.Device,
	queue:         ^MTL.CommandQueue,
	layer:         ^CA.MetalLayer,
	pipeline:      [Texture_Kind]^MTL.RenderPipelineState,
	sampler:       [Texture_Kind]^MTL.SamplerState,
	ebo:           ^MTL.Buffer,
	vbo:           ^MTL.Buffer,
	vbo_used:      int, // bytes of vbo this frame's draws have taken
	storage:       MTL.StorageMode, // for textures (Shared where memory is unified)
	// The frame being drawn (from gpu_begin to gpu_present) and the
	// autorelease pool that the objects used to draw it live in.
	pool:          ^NS.AutoreleasePool,
	drawable:      ^CA.MetalDrawable,
	cmd:           ^MTL.CommandBuffer,
	enc:           ^MTL.RenderCommandEncoder,
	// The last committed frame, until it is known to be done (settle).
	last:          ^MTL.CommandBuffer,
	width, height: i32, // size of the drawable
	clipped_out:   bool, // the clip rect is empty, so there is nothing to draw
	resizing:      bool, // frames are presented together with the window's resize (gpu_resizing)
}

// CATransaction, used for gpu_resizing's frames.
@(private = "file", objc_class = "CATransaction")
Transaction :: struct {
	using _: NS.Object,
}

// What Gpu_Texture points at.
@(private = "file")
Metal_Texture :: struct {
	texture:  ^MTL.Texture,
	borrowed: bool, // owned by somebody else (gpu_texture_wrap), so we must not release it
}

// The same shaders as in the OpenGL backend, written in the Metal Shading
// Language. The two kinds of texture each get their own fragment function
// instead of a uniform to tell them apart.
@(private = "file")
SHADERS :: `#include <metal_stdlib>
using namespace metal;
struct Vertex {
	float2 pos [[attribute(0)]];
	float2 uv [[attribute(1)]];
	float4 color [[attribute(2)]];
};
struct Pixel {
	float4 pos [[position]];
	float2 uv;
	float4 color;
};
vertex Pixel vs(Vertex v [[stage_in]], constant float2 &u_screen [[buffer(1)]]) {
	Pixel p;
	p.pos = float4(v.pos.x / u_screen.x * 2.0 - 1.0, 1.0 - v.pos.y / u_screen.y * 2.0, 0.0, 1.0);
	p.uv = v.uv;
	p.color = v.color;
	return p;
}
// The atlases store coverage in their red channel.
fragment float4 ps_alpha(Pixel p [[stage_in]], texture2d<float> atlas [[texture(0)]], sampler s [[sampler(0)]]) {
	return float4(p.color.rgb, p.color.a * atlas.sample(s, p.uv).r);
}
// Chat images are ordinary color textures.
fragment float4 ps_rgba(Pixel p [[stage_in]], texture2d<float> atlas [[texture(0)]], sampler s [[sampler(0)]]) {
	float4 t = atlas.sample(s, p.uv);
	return float4(t.rgb * p.color.rgb, t.a * p.color.a);
}
`

// The initial size of the vertex buffer. It grows when a frame needs more.
@(private = "file")
VBO_SIZE :: MAX_QUADS * 4 * size_of(Vertex) * 4

// gpu_window_hints asks GLFW for a bare window, because Metal draws into a
// layer of its view.
gpu_window_hints :: proc() {
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
}

GPU_REQUIREMENT :: "Metal"

gpu_init :: proc(g: ^Gpu, window: glfw.WindowHandle) -> (ok: bool) {
	NS.scoped_autoreleasepool()
	defer if !ok {
		gpu_destroy(g)
	}
	g.window = window
	g.device = MTL.CreateSystemDefaultDevice()
	if g.device == nil {
		log.error("gpu: no Metal device")
		return false
	}
	g.queue = g.device->newCommandQueue()
	// Apple's GPUs share memory with the CPU, so a texture is a single copy
	// that both can see. Elsewhere, Managed keeps one copy on each side and
	// syncs them.
	g.storage = .Shared if g.device->hasUnifiedMemory() else .Managed

	g.layer = CA.MetalLayer.layer()
	g.layer->retain()
	g.layer->setDevice(g.device)
	g.layer->setPixelFormat(.BGRA8Unorm)
	g.layer->setFramebufferOnly(true)
	g.layer->setOpaque(true)
	// Use two drawables, like OpenGL's double buffering. A third would take
	// another window's worth of memory for a UI that is mostly idle.
	g.layer->setMaximumDrawableCount(2)
	view := glfw.GetCocoaView(window)
	if view == nil {
		log.error("gpu: the window has no view")
		return false
	}
	// This is how GLFW's own Metal surfaces do it: the layer is set first so
	// the view hosts it instead of creating one of its own.
	view->setLayer(g.layer)
	view->setWantsLayer(true)

	make_pipeline(g) or_return
	return true
}

// make_pipeline compiles the shaders and sets up everything they draw with.
@(private = "file")
make_pipeline :: proc(g: ^Gpu) -> bool {
	src := NS.String.alloc()->initWithOdinString(SHADERS)
	defer src->release()
	library, err := g.device->newLibraryWithSource(src, nil)
	if library == nil {
		log.errorf("gpu: the shaders didn't compile: %s", error_text(err))
		return false
	}
	defer library->release()
	vs := library->newFunctionWithName(NS.AT("vs"))
	defer vs->release()

	vertices := MTL.VertexDescriptor.vertexDescriptor()
	attributes := vertices->attributes()
	for format, i in ([3]MTL.VertexFormat{.Float2, .Float2, .UChar4Normalized}) {
		a := attributes->object(NS.UInteger(i))
		a->setFormat(format)
		a->setBufferIndex(0)
	}
	attributes->object(0)->setOffset(NS.UInteger(offset_of(Vertex, pos)))
	attributes->object(1)->setOffset(NS.UInteger(offset_of(Vertex, uv)))
	attributes->object(2)->setOffset(NS.UInteger(offset_of(Vertex, color)))
	vertices->layouts()->object(0)->setStride(size_of(Vertex))

	for name, kind in ([Texture_Kind]^NS.String{.Alpha = NS.AT("ps_alpha"), .Rgba = NS.AT("ps_rgba")}) {
		fs := library->newFunctionWithName(name)
		defer fs->release()
		desc := MTL.RenderPipelineDescriptor.alloc()->init()
		defer desc->release()
		desc->setVertexFunction(vs)
		desc->setFragmentFunction(fs)
		desc->setVertexDescriptor(vertices)
		color := desc->colorAttachments()->object(0)
		color->setPixelFormat(.BGRA8Unorm)
		// Color blends over what is already there. Alpha is blended the same
		// way as in the OpenGL backend (gpu_gl.odin), although nothing here
		// shows it.
		color->setBlendingEnabled(true)
		color->setRgbBlendOperation(.Add)
		color->setAlphaBlendOperation(.Add)
		color->setSourceRGBBlendFactor(.SourceAlpha)
		color->setDestinationRGBBlendFactor(.OneMinusSourceAlpha)
		color->setSourceAlphaBlendFactor(.One)
		color->setDestinationAlphaBlendFactor(.OneMinusSourceAlpha)
		pipeline, perr := g.device->newRenderPipelineStateWithDescriptor(desc)
		if pipeline == nil {
			log.errorf("gpu: no pipeline for %s: %s", name->odinString(), error_text(perr))
			return false
		}
		g.pipeline[kind] = pipeline
	}

	// Glyphs are drawn 1:1 with physical pixels, so no filtering is wanted.
	// Images are usually drawn smaller than their original size.
	for kind in Texture_Kind {
		desc := MTL.SamplerDescriptor.alloc()->init()
		defer desc->release()
		filter: MTL.SamplerMinMagFilter = .Nearest if kind == .Alpha else .Linear
		desc->setMinFilter(filter)
		desc->setMagFilter(filter)
		desc->setMipFilter(.NotMipmapped if kind == .Alpha else .Linear)
		desc->setSAddressMode(.ClampToEdge)
		desc->setTAddressMode(.ClampToEdge)
		g.sampler[kind] = g.device->newSamplerState(desc)
	}

	indices := quad_indices()
	g.ebo = g.device->newBufferWithBytes(([^]byte)(indices)[:size_of(indices^)], {})
	g.vbo = g.device->newBufferWithLength(VBO_SIZE, {})
	return g.ebo != nil && g.vbo != nil
}

gpu_destroy :: proc(g: ^Gpu) {
	settle(g)
	for &p in g.pipeline {
		release(&p)
	}
	for &s in g.sampler {
		release(&s)
	}
	release(&g.ebo)
	release(&g.vbo)
	if g.layer != nil && g.window != nil {
		if view := glfw.GetCocoaView(g.window); view != nil && view->layer() == g.layer {
			view->setLayer(nil)
		}
	}
	release(&g.layer)
	release(&g.queue)
	release(&g.device)
	g^ = {}
}

// gpu_lost returns whether the device has been lost and has to be set up
// again (renderer_reset). A Metal device is not lost while the process runs,
// except when an external GPU is unplugged, which is not handled.
gpu_lost :: proc(g: ^Gpu) -> bool {
	return g.device == nil
}

// gpu_swap_interval sets how many display refreshes a present waits for:
// 1 for vsync, 0 to not wait (see set_swap_pace).
gpu_swap_interval :: proc(g: ^Gpu, interval: i32) {
	if g.layer != nil {
		g.layer->setDisplaySyncEnabled(NS.BOOL(interval != 0))
	}
}

// gpu_begin starts a frame cleared to `clear`, projecting view_w x view_h
// logical pixels onto the fb_w x fb_h framebuffer. It returns false when
// there is nothing to draw into.
gpu_begin :: proc(g: ^Gpu, fb_w, fb_h: i32, view_w, view_h: f32, clear: mu.Color) -> bool {
	// A minimized window has no size, so it cannot have a drawable either.
	if g.device == nil || fb_w <= 0 || fb_h <= 0 {
		return false
	}
	settle(g)
	g.vbo_used = 0
	g.pool = NS.AutoreleasePool.alloc()->init()

	if fb_w != g.width || fb_h != g.height {
		// The layer stretches its drawable over the view, so the drawable
		// must be the size of the framebuffer to land 1:1 on the window's
		// pixels.
		g.layer->setDrawableSize({NS.Float(fb_w), NS.Float(fb_h)})
		sx, _ := glfw.GetWindowContentScale(g.window)
		g.layer->setContentsScale(NS.Float(sx))
		g.width, g.height = fb_w, fb_h
	}
	g.drawable = g.layer->nextDrawable()
	if g.drawable == nil {
		// The window is not on screen (which causes a wait of up to a second
		// before giving up) or memory ran out.
		g.pool->drain()
		g.pool = nil
		return false
	}

	pass := MTL.RenderPassDescriptor.renderPassDescriptor()
	color := pass->colorAttachments()->object(0)
	color->setTexture(g.drawable->texture())
	color->setLoadAction(.Clear)
	color->setStoreAction(.Store)
	color->setClearColor({f64(clear.r) / 255, f64(clear.g) / 255, f64(clear.b) / 255, 1})
	g.cmd = g.queue->commandBuffer()
	g.enc = g.cmd->renderCommandEncoderWithDescriptor(pass)

	screen := [2]f32{view_w, view_h}
	g.enc->setViewport({0, 0, f64(fb_w), f64(fb_h), 0, 1})
	g.enc->setVertexBytes(([^]byte)(&screen)[:size_of(screen)], 1)
	gpu_clip(g, 0, 0, fb_w, fb_h)
	return true
}

gpu_end :: proc(g: ^Gpu) {
	if g.enc != nil {
		g.enc->endEncoding()
		g.enc = nil
	}
}

// gpu_resizing makes the frames drawn until it is turned off again appear on
// screen in the same Core Animation transaction as the window's new size. It
// is meant for drawing while the window is being resized. When presented the
// usual way, a frame appears a moment after the window has changed size, so
// the window's edge would briefly show the last frame stretched or the clear
// color. The cost is waiting for each frame to be scheduled on the GPU.
gpu_resizing :: proc(g: ^Gpu, on: bool) {
	if g.layer != nil && g.resizing != on {
		g.layer->setPresentsWithTransaction(NS.BOOL(on))
		g.resizing = on
	}
}

gpu_present :: proc(g: ^Gpu) {
	if g.cmd == nil {
		return
	}
	gpu_end(g)
	if g.resizing {
		g.cmd->commit()
		g.cmd->waitUntilScheduled()
		g.drawable->present()
		// The drawable is only released once the transaction is committed,
		// which otherwise happens the next time the run loop goes around. A
		// frame drawn before then (when the size was changed from here
		// instead of by a drag) would wait a second for a drawable.
		intrinsics.objc_send(nil, Transaction, "flush")
	} else {
		g.cmd->presentDrawable(g.drawable)
		g.cmd->commit()
	}
	// Retained beyond the pool's lifetime so the next frame can wait on it.
	g.last = g.cmd
	g.last->retain()
	g.cmd, g.drawable = nil, nil
	g.pool->drain()
	g.pool = nil
}

// gpu_clip limits drawing to a rect of physical pixels, with the origin at
// the top left.
gpu_clip :: proc(g: ^Gpu, x, y, w, h: i32) {
	if g.enc == nil {
		return
	}
	// Metal does not allow a scissor rect that reaches outside the drawable.
	x0, y0 := clamp(x, 0, g.width), clamp(y, 0, g.height)
	x1, y1 := clamp(x + w, 0, g.width), clamp(y + h, 0, g.height)
	g.clipped_out = x1 <= x0 || y1 <= y0
	if !g.clipped_out {
		g.enc->setScissorRect(
			{NS.Integer(x0), NS.Integer(y0), NS.Integer(x1 - x0), NS.Integer(y1 - y0)},
		)
	}
}

// gpu_draw draws quads (four vertices each, see quad_indices) from `tex`.
gpu_draw :: proc(g: ^Gpu, vertices: []Vertex, tex: Gpu_Texture, kind: Texture_Kind) {
	t := (^Metal_Texture)(tex)
	if t == nil || g.enc == nil || g.clipped_out || len(vertices) == 0 {
		return
	}
	bytes := len(vertices) * size_of(Vertex)
	size := int(g.vbo->length())
	if g.vbo_used + bytes > size {
		// The command buffer keeps the old buffer alive for the draws it
		// contains.
		release(&g.vbo)
		g.vbo = g.device->newBufferWithLength(NS.UInteger(max(size * 2, bytes)), {})
		g.vbo_used = 0
		if g.vbo == nil {
			return
		}
	}
	copy(g.vbo->contents()[g.vbo_used:], ([^]byte)(raw_data(vertices))[:bytes])

	g.enc->setRenderPipelineState(g.pipeline[kind])
	g.enc->setVertexBuffer(g.vbo, NS.UInteger(g.vbo_used), 0)
	g.enc->setFragmentTexture(t.texture, 0)
	g.enc->setFragmentSamplerState(g.sampler[kind], 0)
	g.enc->drawIndexedPrimitives(.Triangle, NS.UInteger(len(vertices) / 4 * 6), .UInt16, g.ebo, 0)
	g.vbo_used += bytes
}

// gpu_texture_make creates a width x height texture from `pixels` (one byte
// per pixel for .Alpha, four for .Rgba). As with Direct3D, a texture without
// pixels is not supported (see gpu_d3d11.odin). With `mipmaps`, an .Rgba
// texture gets smaller copies of itself (see gpu_gl.odin).
gpu_texture_make :: proc(
	g: ^Gpu,
	kind: Texture_Kind,
	width, height: i32,
	pixels: []u8,
	mipmaps := false,
) -> Gpu_Texture {
	if pixels == nil || width <= 0 || height <= 0 || g.device == nil {
		return 0
	}
	NS.scoped_autoreleasepool()
	generate := mipmaps && kind == .Rgba
	desc := MTL.TextureDescriptor.texture2DDescriptorWithPixelFormat(
		.R8Unorm if kind == .Alpha else .RGBA8Unorm,
		NS.UInteger(width),
		NS.UInteger(height),
		NS.BOOL(generate),
	)
	desc->setStorageMode(g.storage)
	desc->setUsage({.ShaderRead})
	t := new(Metal_Texture)
	t.texture = g.device->newTextureWithDescriptor(desc)
	if t.texture == nil {
		log.errorf("gpu: no %dx%d texture", width, height)
		free(t)
		return 0
	}
	pixel_size: i32 = 1 if kind == .Alpha else 4
	t.texture->replaceRegion(
		region(0, 0, width, height),
		0,
		raw_data(pixels),
		NS.UInteger(width * pixel_size),
	)
	if generate {
		// The GPU generates them from the first level on a command buffer of
		// its own. The queue runs it before the frame that draws with them,
		// which is committed afterwards.
		cmd := g.queue->commandBuffer()
		blit := cmd->blitCommandEncoder()
		blit->generateMipmapsForTexture(t.texture)
		blit->endEncoding()
		cmd->commit()
	}
	texture_noted(Gpu_Texture(uintptr(t)), kind, width, height, generate)
	return Gpu_Texture(uintptr(t))
}

// gpu_texture_update replaces the whole contents of an .Rgba texture without
// mipmaps with `pixels` (`width` x `height`), for example the next frame of
// an animation.
gpu_texture_update :: proc(g: ^Gpu, tex: Gpu_Texture, width, height: i32, pixels: []u8) {
	t := (^Metal_Texture)(tex)
	if t == nil || len(pixels) < int(width) * int(height) * 4 {
		return
	}
	// The last frame might still be drawing from the previous contents.
	settle(g)
	t.texture->replaceRegion(
		region(0, 0, width, height),
		0,
		raw_data(pixels),
		NS.UInteger(width * 4),
	)
}

// gpu_texture_update_rows replaces rows y0 up to y1 of an .Alpha texture that
// is `width` pixels wide with `rows`.
gpu_texture_update_rows :: proc(g: ^Gpu, tex: Gpu_Texture, width, y0, y1: i32, rows: []u8) {
	t := (^Metal_Texture)(tex)
	if t == nil {
		return
	}
	settle(g)
	t.texture->replaceRegion(region(0, y0, width, y1 - y0), 0, raw_data(rows), NS.UInteger(width))
}

gpu_native :: proc(g: ^Gpu) -> Gpu_Native {
	return {metal_device = g.device, metal_queue = g.queue}
}

// gpu_texture_wrap makes a texture that somebody else created on our device
// drawable. `native` is its id<MTLTexture>. The texture stays owned by its
// creator, and gpu_texture_unwrap forgets it again.
gpu_texture_wrap :: proc(g: ^Gpu, native: uintptr) -> Gpu_Texture {
	if native == 0 {
		return 0
	}
	t := new(Metal_Texture)
	t.texture = (^MTL.Texture)(native)
	t.borrowed = true
	return Gpu_Texture(uintptr(t))
}

gpu_texture_unwrap :: proc(g: ^Gpu, tex: ^Gpu_Texture) {
	if t := (^Metal_Texture)(tex^); t != nil && t.borrowed {
		free(t)
	}
	tex^ = 0
}

// gpu_texture_delete deletes `tex`, if there is one, and sets it to 0. A
// frame on the GPU that draws it keeps it alive until that frame is done.
gpu_texture_delete :: proc(g: ^Gpu, tex: ^Gpu_Texture) {
	if t := (^Metal_Texture)(tex^); t != nil && t.borrowed {
		gpu_texture_unwrap(g, tex)
	} else if t != nil {
		texture_forgotten(tex^)
		release(&t.texture)
		free(t)
	}
	tex^ = 0
}

// settle waits for the last committed frame to finish on the GPU, so the
// buffers and textures it draws from can be written again.
@(private = "file")
settle :: proc(g: ^Gpu) {
	if g.last == nil {
		return
	}
	g.last->waitUntilCompleted()
	if g.last->status() == .Error {
		log.errorf("gpu: a frame failed: %s", error_text(g.last->error()))
	}
	release(&g.last)
}

@(private = "file")
region :: proc(x, y, w, h: i32) -> MTL.Region {
	return {{NS.Integer(x), NS.Integer(y), 0}, {NS.Integer(w), NS.Integer(h), 1}}
}

@(private = "file")
error_text :: proc(err: ^NS.Error) -> string {
	if err == nil {
		return "no reason given"
	}
	return err->localizedDescription()->odinString()
}

// release releases an Objective-C object, if there is one, and clears the
// pointer.
@(private = "file")
release :: proc(p: ^^$T) {
	if p^ != nil {
		p^->release()
		p^ = nil
	}
}
