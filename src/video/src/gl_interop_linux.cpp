/*
VA-API frames into OpenGL through EGL (gl_interop.h). The surface is
mapped as DRM PRIME, which exports it as DMA-BUFs with each plane's
offset, pitch and modifier, and each plane is imported as an EGL image
(R8 for Y, GR88 for UV) bound to a texture. Mapping waits for the
decoder to be done with the surface.

libEGL is loaded at run time (dl_linux.h), like the rest of the
system's libraries.
*/
#include "gl_interop.h"
#include "dl_linux.h"
#include "internal.h"

#include <cstring>
#include <vector>

#include "ffmpeg.h"

// Only types, so after ffmpeg.h.
extern "C" {
#include <libavutil/hwcontext_drm.h>
}

namespace yv {

namespace {

// The little of EGL this needs, without its headers.
using EGLDisplay = void *;
using EGLImage = void *;
using EGLint = int32_t;
using EGLenum = unsigned int;

constexpr EGLint EGL_NONE = 0x3038;
constexpr EGLint EGL_EXTENSIONS = 0x3055;
constexpr EGLint EGL_WIDTH = 0x3057;
constexpr EGLint EGL_HEIGHT = 0x3056;
constexpr EGLenum EGL_LINUX_DMA_BUF_EXT = 0x3270;
constexpr EGLint EGL_LINUX_DRM_FOURCC_EXT = 0x3271;
constexpr EGLint EGL_DMA_BUF_PLANE0_FD_EXT = 0x3272;
constexpr EGLint EGL_DMA_BUF_PLANE0_OFFSET_EXT = 0x3273;
constexpr EGLint EGL_DMA_BUF_PLANE0_PITCH_EXT = 0x3274;
constexpr EGLint EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT = 0x3443;
constexpr EGLint EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT = 0x3444;

constexpr unsigned GL_TEXTURE_2D = 0x0DE1;

constexpr uint32_t fourcc(char a, char b, char c, char d) {
	return static_cast<uint32_t>(a) | static_cast<uint32_t>(b) << 8 |
	       static_cast<uint32_t>(c) << 16 | static_cast<uint32_t>(d) << 24;
}
constexpr uint32_t DRM_FORMAT_R8 = fourcc('R', '8', ' ', ' ');
constexpr uint32_t DRM_FORMAT_GR88 = fourcc('G', 'R', '8', '8');
constexpr uint32_t DRM_FORMAT_NV12 = fourcc('N', 'V', '1', '2');
constexpr uint64_t DRM_FORMAT_MOD_INVALID = 0x00ffffffffffffffULL;
constexpr uint64_t DRM_FORMAT_MOD_LINEAR = 0;

struct Egl {
	EGLDisplay (*GetCurrentDisplay)() = nullptr;
	void *(*GetProcAddress)(const char *) = nullptr;
	const char *(*QueryString)(EGLDisplay, EGLint) = nullptr;
	EGLImage (*CreateImageKHR)(EGLDisplay, void *, EGLenum, void *, const EGLint *) = nullptr;
	unsigned (*DestroyImageKHR)(EGLDisplay, EGLImage) = nullptr;
};

bool has_extension(const char *list, const char *name) {
	size_t n = strlen(name);
	for (const char *p = list; p && (p = strstr(p, name)); p += n) {
		if ((p == list || p[-1] == ' ') && (p[n] == ' ' || p[n] == 0)) {
			return true;
		}
	}
	return false;
}

// One plane of the frame, as EGL wants it.
struct Plane {
	int fd;
	uint32_t offset, pitch;
	uint64_t modifier;
};

class Interop_Egl final : public Gl_Interop {
public:
	Interop_Egl(const Egl &egl, EGLDisplay dpy, bool modifiers, void (*bind_tex)(unsigned, unsigned),
	            void (*target_tex)(unsigned, void *))
		: egl_(egl), dpy_(dpy), modifiers_(modifiers), bind_tex_(bind_tex), target_tex_(target_tex) {}

	~Interop_Egl() override {
		release();
	}

	bool bind(const AVFrame *frame, unsigned y, unsigned uv) override {
		release();
		if (frame->format != AV_PIX_FMT_VAAPI) {
			return false;
		}
		mapped_ = av_frame_alloc();
		mapped_->format = AV_PIX_FMT_DRM_PRIME;
		if (av_hwframe_map(mapped_, frame, AV_HWFRAME_MAP_READ) < 0) {
			log(YV_LOG_INFO, "video: VA-API won't export its frames as DMA-BUFs");
			release();
			return false;
		}
		const auto *d = reinterpret_cast<const AVDRMFrameDescriptor *>(mapped_->data[0]);
		// The planes, whether as one NV12 layer or a layer each.
		std::vector<Plane> planes;
		bool known = true;
		for (int l = 0; l < d->nb_layers; l++) {
			const AVDRMLayerDescriptor &layer = d->layers[l];
			known = known && (layer.format == DRM_FORMAT_NV12 ||
			                  layer.format == (l == 0 ? DRM_FORMAT_R8 : DRM_FORMAT_GR88));
			for (int p = 0; p < layer.nb_planes; p++) {
				const AVDRMPlaneDescriptor &pl = layer.planes[p];
				const AVDRMObjectDescriptor &obj = d->objects[pl.object_index];
				planes.push_back({obj.fd, static_cast<uint32_t>(pl.offset),
				                  static_cast<uint32_t>(pl.pitch), obj.format_modifier});
			}
		}
		if (!known || planes.size() != 2) {
			log(YV_LOG_INFO, "video: VA-API's frames aren't 8 bit NV12 here");
			release();
			return false;
		}
		int w = frame->width, h = frame->height;
		images_[0] = image(planes[0], DRM_FORMAT_R8, w, h);
		images_[1] = image(planes[1], DRM_FORMAT_GR88, (w + 1) / 2, (h + 1) / 2);
		if (!images_[0] || !images_[1]) {
			log(YV_LOG_INFO, "video: EGL won't take VA-API's DMA-BUFs");
			release();
			return false;
		}
		bind_tex_(GL_TEXTURE_2D, y);
		target_tex_(GL_TEXTURE_2D, images_[0]);
		bind_tex_(GL_TEXTURE_2D, uv);
		target_tex_(GL_TEXTURE_2D, images_[1]);
		return true;
	}

	void release() override {
		for (EGLImage &img : images_) {
			if (img) {
				egl_.DestroyImageKHR(dpy_, img);
				img = nullptr;
			}
		}
		av_frame_free(&mapped_);
	}

private:
	Egl egl_;
	EGLDisplay dpy_;
	bool modifiers_;
	void (*bind_tex_)(unsigned, unsigned);
	void (*target_tex_)(unsigned, void *);
	AVFrame *mapped_ = nullptr; // the DRM PRIME mapping, holding the surface
	EGLImage images_[2] = {};

	EGLImage image(const Plane &p, uint32_t format, int w, int h) {
		std::vector<EGLint> a = {
			EGL_WIDTH,
			w,
			EGL_HEIGHT,
			h,
			EGL_LINUX_DRM_FOURCC_EXT,
			static_cast<EGLint>(format),
			EGL_DMA_BUF_PLANE0_FD_EXT,
			p.fd,
			EGL_DMA_BUF_PLANE0_OFFSET_EXT,
			static_cast<EGLint>(p.offset),
			EGL_DMA_BUF_PLANE0_PITCH_EXT,
			static_cast<EGLint>(p.pitch),
		};
		if (modifiers_ && p.modifier != DRM_FORMAT_MOD_INVALID) {
			a.insert(a.end(), {EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT,
			                   static_cast<EGLint>(p.modifier & 0xffffffff),
			                   EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT,
			                   static_cast<EGLint>(p.modifier >> 32)});
		} else if (p.modifier != DRM_FORMAT_MOD_INVALID && p.modifier != DRM_FORMAT_MOD_LINEAR) {
			return nullptr; // tiled, and EGL can't be told how
		}
		a.push_back(EGL_NONE);
		return egl_.CreateImageKHR(dpy_, nullptr, EGL_LINUX_DMA_BUF_EXT, nullptr, a.data());
	}
};

} // namespace

std::unique_ptr<Gl_Interop> make_gl_interop(void *(*get_proc)(const char *)) {
	if (!vaapi_installed()) {
		return nullptr;
	}
	static Dl_Lib lib;
	static Egl egl;
	static bool loaded = [] {
		return lib.open({"libEGL.so.1"}) && lib.sym(egl.GetCurrentDisplay, "eglGetCurrentDisplay") &&
		       lib.sym(egl.GetProcAddress, "eglGetProcAddress") &&
		       lib.sym(egl.QueryString, "eglQueryString");
	}();
	if (!loaded) {
		return nullptr;
	}
	EGLDisplay dpy = egl.GetCurrentDisplay();
	if (!dpy) {
		log(YV_LOG_INFO, "video: the client's OpenGL isn't EGL's (GLX on X11), so pictures go "
		                 "through memory");
		return nullptr;
	}
	const char *exts = egl.QueryString(dpy, EGL_EXTENSIONS);
	if (!has_extension(exts, "EGL_EXT_image_dma_buf_import")) {
		log(YV_LOG_INFO, "video: EGL can't import DMA-BUFs, so pictures go through memory");
		return nullptr;
	}
	Egl e = egl;
	e.CreateImageKHR = reinterpret_cast<decltype(e.CreateImageKHR)>(
		egl.GetProcAddress("eglCreateImageKHR"));
	e.DestroyImageKHR = reinterpret_cast<decltype(e.DestroyImageKHR)>(
		egl.GetProcAddress("eglDestroyImageKHR"));
	auto bind_tex =
		reinterpret_cast<void (*)(unsigned, unsigned)>(get_proc("glBindTexture"));
	auto target_tex = reinterpret_cast<void (*)(unsigned, void *)>(
		get_proc("glEGLImageTargetTexture2DOES"));
	if (!e.CreateImageKHR || !e.DestroyImageKHR || !bind_tex || !target_tex) {
		log(YV_LOG_INFO, "video: EGL images aren't there, so pictures go through memory");
		return nullptr;
	}
	bool modifiers = has_extension(exts, "EGL_EXT_image_dma_buf_import_modifiers");
	log(YV_LOG_INFO, "video: VA-API's pictures go to OpenGL as DMA-BUFs");
	return std::make_unique<Interop_Egl>(e, dpy, modifiers, bind_tex, target_tex);
}

} // namespace yv
