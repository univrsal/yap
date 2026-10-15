/*
Showing a frame decoded on the GPU through OpenGL without bringing it
through memory (output_gl.cpp): its two NV12 planes are made into GL
textures where they lie, and the usual shader converts them.

On Linux (gl_interop_linux.cpp), a VA-API surface is exported as
DMA-BUFs (av_hwframe_map to DRM PRIME) and imported as one EGL image a
plane. Needs the client's context to be EGL's, which it is on Wayland;
GLX (X11) has no way in, so there's no interop there.

Everything here is the drawing thread's, with the client's context
current.
*/
#pragma once

#include <memory>

extern "C" {
#include <libavutil/frame.h>
}

namespace yv {

class Gl_Interop {
public:
	virtual ~Gl_Interop() = default;

	/*
	bind makes GL_TEXTURE_2D textures `y` and `uv` show
	`frame`'s planes, which stay until release. False if it can't, which
	the caller takes to mean it never will, and goes through memory.
	*/
	virtual bool bind(const AVFrame *frame, unsigned y, unsigned uv) = 0;

	// release lets go of what bind took. Called before the next bind, by
	// when the GPU has long drawn from it.
	virtual void release() = 0;
};

// make_gl_interop is the interop for the current context, or nullptr if
// there's none (the log says why).
std::unique_ptr<Gl_Interop> make_gl_interop(void *(*get_proc)(const char *));

} // namespace yv
