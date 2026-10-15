/*
Watching with OpenGL (Linux). The newest frame waits until present
converts its two NV12 planes into an RGBA texture with a small shader,
in the client's context.

A frame decoded in hardware (VA-API) is kept as it is, and its planes
become textures where they lie (gl_interop.h): EGL images of its
DMA-BUFs. Where that can't be done (GLX on X11, a driver that won't),
frames are copied back
to memory as they're decoded and present uploads them, which at 1440p60
is about 330 MB/s. The first frame that won't go the GPU's way is
copied back where it is, and the rest go through memory from then on.

The client's GL state is put back as it was after present draws.
*/
#include "gl_interop.h"
#include "output.h"

#include <atomic>
#include <cstdlib>
#include <cstring>

extern "C" {
#include <libavutil/hwcontext.h>
}

namespace yv {

namespace {

// The little of OpenGL 3.3 core this needs, loaded through gl_get_proc.
using GLenum = unsigned int;
using GLuint = unsigned int;
using GLint = int;
using GLsizei = int;
using GLboolean = unsigned char;
using GLchar = char;
using GLfloat = float;

constexpr GLenum GL_TEXTURE_2D = 0x0DE1;
constexpr GLenum GL_TEXTURE0 = 0x84C0;
constexpr GLenum GL_TEXTURE_MIN_FILTER = 0x2801;
constexpr GLenum GL_TEXTURE_MAG_FILTER = 0x2800;
constexpr GLenum GL_TEXTURE_WRAP_S = 0x2802;
constexpr GLenum GL_TEXTURE_WRAP_T = 0x2803;
constexpr GLenum GL_CLAMP_TO_EDGE = 0x812F;
constexpr GLenum GL_LINEAR = 0x2601;
constexpr GLenum GL_R8 = 0x8229;
constexpr GLenum GL_RG8 = 0x822B;
constexpr GLenum GL_RED = 0x1903;
constexpr GLenum GL_RG = 0x8227;
constexpr GLenum GL_RGBA8 = 0x8058;
constexpr GLenum GL_RGBA = 0x1908;
constexpr GLenum GL_UNSIGNED_BYTE = 0x1401;
constexpr GLenum GL_UNPACK_ALIGNMENT = 0x0CF5;
constexpr GLenum GL_UNPACK_ROW_LENGTH = 0x0CF2;
constexpr GLenum GL_FRAMEBUFFER = 0x8D40;
constexpr GLenum GL_COLOR_ATTACHMENT0 = 0x8CE0;
constexpr GLenum GL_FRAMEBUFFER_COMPLETE = 0x8CD5;
constexpr GLenum GL_FRAMEBUFFER_BINDING = 0x8CA6;
constexpr GLenum GL_VERTEX_SHADER = 0x8B31;
constexpr GLenum GL_FRAGMENT_SHADER = 0x8B30;
constexpr GLenum GL_COMPILE_STATUS = 0x8B81;
constexpr GLenum GL_LINK_STATUS = 0x8B82;
constexpr GLenum GL_TRIANGLES = 0x0004;
constexpr GLenum GL_VIEWPORT = 0x0BA2;
constexpr GLenum GL_CURRENT_PROGRAM = 0x8B8D;
constexpr GLenum GL_VERTEX_ARRAY_BINDING = 0x85B5;
constexpr GLenum GL_ACTIVE_TEXTURE = 0x84E0;
constexpr GLenum GL_TEXTURE_BINDING_2D = 0x8069;
constexpr GLenum GL_BLEND = 0x0BE2;
constexpr GLenum GL_SCISSOR_TEST = 0x0C11;

#define GL_FUNCS(X)                                                                               \
	X(void, GenTextures, GLsizei, GLuint *)                                                       \
	X(void, DeleteTextures, GLsizei, const GLuint *)                                              \
	X(void, BindTexture, GLenum, GLuint)                                                          \
	X(void, ActiveTexture, GLenum)                                                                \
	X(void, TexImage2D, GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum,           \
	  const void *)                                                                               \
	X(void, TexSubImage2D, GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum,        \
	  const void *)                                                                               \
	X(void, TexParameteri, GLenum, GLenum, GLint)                                                 \
	X(void, PixelStorei, GLenum, GLint)                                                           \
	X(void, GenFramebuffers, GLsizei, GLuint *)                                                   \
	X(void, DeleteFramebuffers, GLsizei, const GLuint *)                                          \
	X(void, BindFramebuffer, GLenum, GLuint)                                                      \
	X(void, FramebufferTexture2D, GLenum, GLenum, GLenum, GLuint, GLint)                          \
	X(GLenum, CheckFramebufferStatus, GLenum)                                                     \
	X(GLuint, CreateShader, GLenum)                                                               \
	X(void, ShaderSource, GLuint, GLsizei, const GLchar *const *, const GLint *)                  \
	X(void, CompileShader, GLuint)                                                                \
	X(void, GetShaderiv, GLuint, GLenum, GLint *)                                                 \
	X(void, GetShaderInfoLog, GLuint, GLsizei, GLsizei *, GLchar *)                               \
	X(void, DeleteShader, GLuint)                                                                 \
	X(GLuint, CreateProgram)                                                                      \
	X(void, AttachShader, GLuint, GLuint)                                                         \
	X(void, LinkProgram, GLuint)                                                                  \
	X(void, GetProgramiv, GLuint, GLenum, GLint *)                                                \
	X(void, DeleteProgram, GLuint)                                                                \
	X(void, UseProgram, GLuint)                                                                   \
	X(GLint, GetUniformLocation, GLuint, const GLchar *)                                          \
	X(void, Uniform1i, GLint, GLint)                                                              \
	X(void, Uniform2f, GLint, GLfloat, GLfloat)                                                   \
	X(void, Uniform4fv, GLint, GLsizei, const GLfloat *)                                          \
	X(void, GenVertexArrays, GLsizei, GLuint *)                                                   \
	X(void, DeleteVertexArrays, GLsizei, const GLuint *)                                          \
	X(void, BindVertexArray, GLuint)                                                              \
	X(void, DrawArrays, GLenum, GLint, GLsizei)                                                   \
	X(void, Viewport, GLint, GLint, GLsizei, GLsizei)                                             \
	X(void, GetIntegerv, GLenum, GLint *)                                                         \
	X(GLboolean, IsEnabled, GLenum)                                                               \
	X(void, Enable, GLenum)                                                                       \
	X(void, Disable, GLenum)

struct Gl {
#define X(ret, name, ...) ret (*name)(__VA_ARGS__) = nullptr;
	GL_FUNCS(X)
#undef X

	bool load(void *(*get)(const char *)) {
		bool ok = true;
#define X(ret, name, ...)                                                                         \
	name = reinterpret_cast<ret (*)(__VA_ARGS__)>(get("gl" #name));                                \
	ok = ok && name != nullptr;
		GL_FUNCS(X)
#undef X
		return ok;
	}
};

const char VERTEX[] = R"(#version 330 core
uniform vec2 uv_scale;
out vec2 uv;
// One triangle that covers the whole target, from the vertex ids alone.
// The picture's top row goes to the texture's first row, as the client
// expects of a picture uploaded from memory.
void main() {
	vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
	uv = p * uv_scale;
	gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
)";

const char FRAGMENT[] = R"(#version 330 core
uniform sampler2D plane_y;
uniform sampler2D plane_uv;
uniform vec4 rows[3];
in vec2 uv;
out vec4 frag;
void main() {
	vec4 yuv = vec4(texture(plane_y, uv).r, texture(plane_uv, uv).rg, 1.0);
	frag = vec4(dot(rows[0], yuv), dot(rows[1], yuv), dot(rows[2], yuv), 1.0);
}
)";

// Whether frames decoded in hardware go to GL as they are (interop_).
enum Interop_State { INTEROP_UNKNOWN, INTEROP_WORKS, INTEROP_NONE };

class Output_GL final : public Output {
public:
	~Output_GL() override {
		av_buffer_unref(&hw_device_);
		av_frame_free(&sw_);
		av_frame_free(&latest_hw_);
		interop_.reset();
		// GL objects can only go with the context current, which it may
		// not be here; set_gpu(nullptr) lets go of them properly.
	}

	AVBufferRef *hw_device() override {
		if (software_only()) {
			return nullptr;
		}
		if (!tried_device_) {
			tried_device_ = true;
			AVHWDeviceType type = AV_HWDEVICE_TYPE_VAAPI;
			Quiet_FFmpeg quiet;
			if (!vaapi_installed()) {
				return nullptr;
			}
			if (av_hwdevice_ctx_create(&hw_device_, type, nullptr, nullptr, 0) < 0) {
				log(YV_LOG_INFO, "video: no hardware decoding (%s)",
				    av_hwdevice_get_type_name(type));
			}
		}
		return hw_device_ ? av_buffer_ref(hw_device_) : nullptr;
	}

	// AV1 in hardware isn't tried yet (FFmpeg's AV1 decoder has no
	// software fallback to find out with); dav1d does it.
	bool hw_decodes(yv_codec codec) override {
		return codec != YV_CODEC_AV1 && hw_device_ != nullptr;
	}

	bool device_stale() override {
		return false;
	}

	void renew_device() override {}

	bool submit(const AVFrame *frame) override {
		const AVFrame *f = frame;
		bool hardware = frame->hw_frames_ctx != nullptr;
		if (hardware && interop_state_.load() != INTEROP_NONE) {
			// Kept on the GPU for present.
			if (AVFrame *keep = av_frame_clone(frame)) {
				std::lock_guard<std::mutex> lock(mutex_);
				av_frame_free(&latest_hw_);
				latest_hw_ = keep;
				noted(frame, frame->width, frame->height, true);
				return true;
			}
		}
		if (hardware) {
			if (!sw_) {
				sw_ = av_frame_alloc();
			}
			av_frame_unref(sw_);
			if (av_hwframe_transfer_data(sw_, frame, 0) < 0 || av_frame_copy_props(sw_, frame) < 0) {
				return false;
			}
			f = sw_;
		}
		f = nv12_.convert(f);
		if (!f) {
			return false;
		}
		std::lock_guard<std::mutex> lock(mutex_);
		av_frame_free(&latest_hw_);
		copy_planes(f);
		noted(frame, f->width, f->height, hardware);
		return true;
	}

	void clear() override {
		std::lock_guard<std::mutex> lock(mutex_);
		av_frame_free(&latest_hw_);
		fresh_ = false;
		frames_ = 0;
		cleared_ = true;
	}

	void set_gpu(const yv_gpu *gpu, uint64_t) override {
		auto get = gpu && gpu->kind == YV_GPU_GL ? gpu->gl_get_proc : nullptr;
		if (get == get_proc_ && get) {
			return;
		}
		drop_gl();
		get_proc_ = get;
		gl_ok_ = get && gl_.load(get);
		// A new context may take the GPU's frames where the old didn't.
		interop_state_.store(INTEROP_UNKNOWN);
		if (get && !gl_ok_) {
			log(YV_LOG_ERROR, "video: OpenGL 3.3 functions missing");
		}
		have_picture_ = false;
		std::lock_guard<std::mutex> lock(mutex_);
		fresh_ = latest_w_ > 0; // upload the newest again, to the new context
	}

	bool present(yv_picture *out) override {
		if (!gl_ok_) {
			return false;
		}
		{
			std::lock_guard<std::mutex> lock(mutex_);
			if (cleared_) {
				cleared_ = false;
				have_picture_ = false;
			}
			out->frames = frames_;
			if (fresh_) {
				fresh_ = false;
				if (draw()) {
					have_picture_ = true;
					hardware_ = latest_hardware_;
					pts_ = latest_pts_;
				}
			}
		}
		if (!have_picture_) {
			return false;
		}
		out->texture = rgba_;
		out->width = rgba_w_;
		out->height = rgba_h_;
		out->hardware = hardware_;
		out->pts_us = pts_;
		return true;
	}

private:
	// The decoder thread's.
	AVBufferRef *hw_device_ = nullptr;
	bool tried_device_ = false;
	AVFrame *sw_ = nullptr;
	Nv12 nv12_;

	// The newest frame, under mutex_: on the GPU (latest_hw_), or its
	// planes in memory.
	std::mutex mutex_;
	AVFrame *latest_hw_ = nullptr;
	std::vector<uint8_t> latest_y_, latest_uv_;
	int latest_w_ = 0, latest_h_ = 0;
	Yuv_Matrix latest_matrix_{};
	bool latest_hardware_ = false;
	uint64_t latest_pts_ = 0;
	bool fresh_ = false;
	bool cleared_ = false;
	uint64_t frames_ = 0;
	std::atomic<int> interop_state_{INTEROP_UNKNOWN};

	// The drawing thread's.
	std::unique_ptr<Gl_Interop> interop_;
	GLuint hw_y_ = 0, hw_uv_ = 0;
	Nv12 draw_nv12_; // for the one frame copied back here
	void *(*get_proc_)(const char *) = nullptr;
	Gl gl_;
	bool gl_ok_ = false;
	GLuint program_ = 0, vao_ = 0, fbo_ = 0;
	GLuint plane_y_ = 0, plane_uv_ = 0, rgba_ = 0;
	int planes_w_ = 0, planes_h_ = 0, rgba_w_ = 0, rgba_h_ = 0;
	bool have_picture_ = false;
	bool hardware_ = false;
	uint64_t pts_ = 0;

	// noted records the newest frame's particulars. With mutex_ held.
	void noted(const AVFrame *frame, int w, int h, bool hardware) {
		latest_w_ = w;
		latest_h_ = h;
		latest_matrix_ = yuv_matrix(frame);
		latest_hardware_ = hardware;
		latest_pts_ = static_cast<uint64_t>(frame->pts);
		fresh_ = true;
		frames_++;
	}

	// copy_planes keeps an NV12 frame's planes for uploading. With
	// mutex_ held.
	void copy_planes(const AVFrame *f) {
		int cw = (f->width + 1) / 2, ch = (f->height + 1) / 2;
		latest_y_.resize(static_cast<size_t>(f->width) * f->height);
		latest_uv_.resize(static_cast<size_t>(cw) * 2 * ch);
		for (int y = 0; y < f->height; y++) {
			memcpy(&latest_y_[static_cast<size_t>(y) * f->width], f->data[0] + y * f->linesize[0],
			       f->width);
		}
		for (int y = 0; y < ch; y++) {
			memcpy(&latest_uv_[static_cast<size_t>(y) * cw * 2], f->data[1] + y * f->linesize[1],
			       cw * 2);
		}
	}

	/*
	bind_hw makes the GPU frame's planes into hw_y_ and hw_uv_, if it can.
	If it can't, it's the last time it's tried: the frame is copied back
	here (and the decoder copies the rest back itself), and false. With
	mutex_ held.
	*/
	bool bind_hw() {
		// YAP_VIDEO_NO_INTEROP=1 copies through memory anyway, to compare.
		if (!interop_ && interop_state_.load() == INTEROP_UNKNOWN && !getenv("YAP_VIDEO_NO_INTEROP")) {
			interop_ = make_gl_interop(get_proc_);
		}
		if (interop_) {
			if (!hw_y_) {
				// Without mipmaps, so filtered linearly: the default
				// filter would leave them incomplete, and black.
				for (GLuint *tex : {&hw_y_, &hw_uv_}) {
					gl_.GenTextures(1, tex);
					gl_.BindTexture(GL_TEXTURE_2D, *tex);
					gl_.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
					gl_.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
					gl_.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
					gl_.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
				}
				gl_.BindTexture(GL_TEXTURE_2D, 0);
			}
			if (interop_->bind(latest_hw_, hw_y_, hw_uv_)) {
				interop_state_.store(INTEROP_WORKS);
				return true;
			}
			interop_.reset();
		}
		interop_state_.store(INTEROP_NONE);
		AVFrame *sw = av_frame_alloc();
		const AVFrame *f = nullptr;
		if (sw && av_hwframe_transfer_data(sw, latest_hw_, 0) >= 0) {
			f = draw_nv12_.convert(sw);
		}
		if (f) {
			copy_planes(f);
		}
		av_frame_free(&sw);
		av_frame_free(&latest_hw_);
		if (!f) {
			latest_w_ = 0; // nothing to draw
		}
		return false;
	}

	void drop_gl() {
		if (interop_) {
			interop_->release();
			interop_.reset();
		}
		if (gl_ok_) {
			GLuint tex[5] = {plane_y_, plane_uv_, rgba_, hw_y_, hw_uv_};
			gl_.DeleteTextures(5, tex);
			if (fbo_) {
				gl_.DeleteFramebuffers(1, &fbo_);
			}
			if (vao_) {
				gl_.DeleteVertexArrays(1, &vao_);
			}
			if (program_) {
				gl_.DeleteProgram(program_);
			}
		}
		program_ = vao_ = fbo_ = plane_y_ = plane_uv_ = rgba_ = 0;
		hw_y_ = hw_uv_ = 0;
		planes_w_ = planes_h_ = rgba_w_ = rgba_h_ = 0;
		gl_ok_ = false;
	}

	GLuint shader(GLenum type, const char *src) {
		GLuint s = gl_.CreateShader(type);
		gl_.ShaderSource(s, 1, &src, nullptr);
		gl_.CompileShader(s);
		GLint ok = 0;
		gl_.GetShaderiv(s, GL_COMPILE_STATUS, &ok);
		if (!ok) {
			char info[512];
			gl_.GetShaderInfoLog(s, sizeof(info), nullptr, info);
			log(YV_LOG_ERROR, "video: shader: %s", info);
			gl_.DeleteShader(s);
			return 0;
		}
		return s;
	}

	// link makes a program of VERTEX and `fragment`, or 0.
	GLuint link(const char *fragment) {
		GLuint vs = shader(GL_VERTEX_SHADER, VERTEX);
		GLuint fs = shader(GL_FRAGMENT_SHADER, fragment);
		if (!vs || !fs) {
			return 0;
		}
		GLuint p = gl_.CreateProgram();
		gl_.AttachShader(p, vs);
		gl_.AttachShader(p, fs);
		gl_.LinkProgram(p);
		gl_.DeleteShader(vs);
		gl_.DeleteShader(fs);
		GLint ok = 0;
		gl_.GetProgramiv(p, GL_LINK_STATUS, &ok);
		if (!ok) {
			log(YV_LOG_ERROR, "video: the shaders don't link");
			gl_.DeleteProgram(p);
			return 0;
		}
		return p;
	}

	bool make_program() {
		program_ = link(FRAGMENT);
		if (!program_) {
			return false;
		}
		gl_.GenVertexArrays(1, &vao_);
		gl_.GenFramebuffers(1, &fbo_);
		return true;
	}

	void make_texture(GLuint &tex, GLint internal, GLenum format, int w, int h) {
		if (!tex) {
			gl_.GenTextures(1, &tex);
		}
		gl_.BindTexture(GL_TEXTURE_2D, tex);
		gl_.TexImage2D(GL_TEXTURE_2D, 0, internal, w, h, 0, format, GL_UNSIGNED_BYTE, nullptr);
		gl_.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
		gl_.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
		gl_.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
		gl_.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	}

	// draw uploads the newest frame and converts it into rgba_. Called
	// with mutex_ held.
	bool draw() {
		if (!program_ && !make_program()) {
			gl_ok_ = false;
			return false;
		}
		// What the client had, to put back.
		GLint fb = 0, vp[4], prog = 0, vao = 0, active = 0, tex0 = 0, tex1 = 0, align = 4,
		      row_len = 0;
		gl_.GetIntegerv(GL_FRAMEBUFFER_BINDING, &fb);
		gl_.GetIntegerv(GL_VIEWPORT, vp);
		gl_.GetIntegerv(GL_CURRENT_PROGRAM, &prog);
		gl_.GetIntegerv(GL_VERTEX_ARRAY_BINDING, &vao);
		gl_.GetIntegerv(GL_ACTIVE_TEXTURE, &active);
		gl_.GetIntegerv(GL_UNPACK_ALIGNMENT, &align);
		gl_.GetIntegerv(GL_UNPACK_ROW_LENGTH, &row_len);
		gl_.ActiveTexture(GL_TEXTURE0);
		gl_.GetIntegerv(GL_TEXTURE_BINDING_2D, &tex0);
		gl_.ActiveTexture(GL_TEXTURE0 + 1);
		gl_.GetIntegerv(GL_TEXTURE_BINDING_2D, &tex1);
		GLboolean blend = gl_.IsEnabled(GL_BLEND);
		GLboolean scissor = gl_.IsEnabled(GL_SCISSOR_TEST);

		// The planes: the GPU frame's own, or uploaded.
		gl_.ActiveTexture(GL_TEXTURE0);
		bool on_gpu = latest_hw_ && bind_hw();
		GLuint y_tex = on_gpu ? hw_y_ : plane_y_, uv_tex = on_gpu ? hw_uv_ : plane_uv_;
		GLuint program = program_;
		int w = latest_w_, h = latest_h_, cw = (w + 1) / 2, ch = (h + 1) / 2;
		if (!on_gpu && w > 0) {
			gl_.PixelStorei(GL_UNPACK_ALIGNMENT, 1);
			gl_.PixelStorei(GL_UNPACK_ROW_LENGTH, 0);
			if (planes_w_ != w || planes_h_ != h) {
				make_texture(plane_y_, GL_R8, GL_RED, w, h);
				make_texture(plane_uv_, GL_RG8, GL_RG, cw, ch);
				planes_w_ = w;
				planes_h_ = h;
			}
			gl_.BindTexture(GL_TEXTURE_2D, plane_y_);
			gl_.TexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, h, GL_RED, GL_UNSIGNED_BYTE,
			                  latest_y_.data());
			gl_.BindTexture(GL_TEXTURE_2D, plane_uv_);
			gl_.TexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, cw, ch, GL_RG, GL_UNSIGNED_BYTE,
			                  latest_uv_.data());
		}
		bool ok = w > 0 && program != 0;
		if (ok && (rgba_w_ != w || rgba_h_ != h)) {
			make_texture(rgba_, GL_RGBA8, GL_RGBA, w, h);
			rgba_w_ = w;
			rgba_h_ = h;
		}
		if (ok) {
			gl_.BindFramebuffer(GL_FRAMEBUFFER, fbo_);
			gl_.FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, rgba_, 0);
			if (gl_.CheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
				log(YV_LOG_ERROR, "video: can't draw into a %dx%d texture", w, h);
				ok = false;
			}
		}
		if (ok) {
			gl_.Disable(GL_BLEND);
			gl_.Disable(GL_SCISSOR_TEST);
			gl_.Viewport(0, 0, w, h);
			gl_.UseProgram(program);
			gl_.Uniform1i(gl_.GetUniformLocation(program, "plane_y"), 0);
			gl_.Uniform1i(gl_.GetUniformLocation(program, "plane_uv"), 1);
			gl_.Uniform4fv(gl_.GetUniformLocation(program, "rows"), 3, &latest_matrix_.rows[0][0]);
			gl_.Uniform2f(gl_.GetUniformLocation(program, "uv_scale"), 1.0f, 1.0f);
			gl_.ActiveTexture(GL_TEXTURE0);
			gl_.BindTexture(GL_TEXTURE_2D, y_tex);
			gl_.ActiveTexture(GL_TEXTURE0 + 1);
			gl_.BindTexture(GL_TEXTURE_2D, uv_tex);
			gl_.BindVertexArray(vao_);
			gl_.DrawArrays(GL_TRIANGLES, 0, 3);
		}
		gl_.BindFramebuffer(GL_FRAMEBUFFER, static_cast<GLuint>(fb));
		gl_.Viewport(vp[0], vp[1], vp[2], vp[3]);
		gl_.UseProgram(static_cast<GLuint>(prog));
		gl_.BindVertexArray(static_cast<GLuint>(vao));
		gl_.ActiveTexture(GL_TEXTURE0 + 1);
		gl_.BindTexture(GL_TEXTURE_2D, static_cast<GLuint>(tex1));
		gl_.ActiveTexture(GL_TEXTURE0);
		gl_.BindTexture(GL_TEXTURE_2D, static_cast<GLuint>(tex0));
		gl_.ActiveTexture(static_cast<GLenum>(active));
		gl_.PixelStorei(GL_UNPACK_ALIGNMENT, align);
		gl_.PixelStorei(GL_UNPACK_ROW_LENGTH, row_len);
		if (blend) {
			gl_.Enable(GL_BLEND);
		}
		if (scissor) {
			gl_.Enable(GL_SCISSOR_TEST);
		}
		return ok;
	}
};

} // namespace

std::unique_ptr<Output> make_output() {
	return std::make_unique<Output_GL>();
}

uint64_t gpu_luid(const yv_gpu *) {
	return 0;
}

} // namespace yv
