/*
VideoToolbox frames into OpenGL (gl_interop.h). A decoded frame is a
CVPixelBuffer backed by an IOSurface, and CGL binds each of its planes
to a rectangle texture: Y as R8, UV as RG8. The buffer is held until
release, so the decoder can't reuse it while it's drawn from.
*/
#include "gl_interop.h"
#include "internal.h"

#include <CoreVideo/CoreVideo.h>
#include <IOSurface/IOSurface.h>
#include <OpenGL/CGLIOSurface.h>
#include <OpenGL/OpenGL.h>

namespace yv {

namespace {

// From gl3.h, which would clash with output_gl.cpp's own.
constexpr unsigned TEXTURE_RECTANGLE = 0x84F5;
constexpr unsigned R8 = 0x8229;
constexpr unsigned RG8 = 0x822B;
constexpr unsigned RED = 0x1903;
constexpr unsigned RG = 0x8227;
constexpr unsigned UNSIGNED_BYTE = 0x1401;

class Interop_Mac final : public Gl_Interop {
public:
	explicit Interop_Mac(void (*bind_tex)(unsigned, unsigned)) : bind_tex_(bind_tex) {}

	~Interop_Mac() override {
		release();
	}

	unsigned target() const override {
		return TEXTURE_RECTANGLE;
	}

	bool bind(const AVFrame *frame, unsigned y, unsigned uv) override {
		release();
		if (frame->format != AV_PIX_FMT_VIDEOTOOLBOX) {
			return false;
		}
		auto pb = reinterpret_cast<CVPixelBufferRef>(frame->data[3]);
		IOSurfaceRef surface = pb ? CVPixelBufferGetIOSurface(pb) : nullptr;
		OSType fmt = pb ? CVPixelBufferGetPixelFormatType(pb) : 0;
		if (!surface || (fmt != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
		                 fmt != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)) {
			log(YV_LOG_INFO, "video: VideoToolbox's frames aren't 8 bit NV12 in an IOSurface");
			return false;
		}
		CGLContextObj cgl = CGLGetCurrentContext();
		bool ok = cgl != nullptr;
		unsigned tex[2] = {y, uv};
		unsigned internal[2] = {R8, RG8};
		unsigned format[2] = {RED, RG};
		for (int p = 0; ok && p < 2; p++) {
			bind_tex_(TEXTURE_RECTANGLE, tex[p]);
			ok = CGLTexImageIOSurface2D(cgl, TEXTURE_RECTANGLE, internal[p],
			                            static_cast<GLsizei>(IOSurfaceGetWidthOfPlane(surface, p)),
			                            static_cast<GLsizei>(IOSurfaceGetHeightOfPlane(surface, p)),
			                            format[p], UNSIGNED_BYTE, surface, p) == kCGLNoError;
		}
		bind_tex_(TEXTURE_RECTANGLE, 0);
		if (!ok) {
			log(YV_LOG_INFO, "video: CGL won't bind VideoToolbox's IOSurfaces");
			return false;
		}
		held_ = CVPixelBufferRetain(pb);
		return true;
	}

	void release() override {
		if (held_) {
			CVPixelBufferRelease(held_);
			held_ = nullptr;
		}
	}

private:
	void (*bind_tex_)(unsigned, unsigned);
	CVPixelBufferRef held_ = nullptr;
};

} // namespace

std::unique_ptr<Gl_Interop> make_gl_interop(void *(*get_proc)(const char *)) {
	auto bind_tex = reinterpret_cast<void (*)(unsigned, unsigned)>(get_proc("glBindTexture"));
	if (!bind_tex || !CGLGetCurrentContext()) {
		return nullptr;
	}
	log(YV_LOG_INFO, "video: VideoToolbox's pictures go to OpenGL as IOSurfaces");
	return std::make_unique<Interop_Mac>(bind_tex);
}

} // namespace yv
