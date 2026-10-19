// YUV to RGB, the same for both outputs (output.h).
#include "output.h"

#include <array>
#include <cstdlib>
#include <cstring>

#include "ffmpeg.h"

namespace yv {

/*
From the matrix's luma weights Kr and Kb:

	R = Y + 2(1 - Kr) V
	G = Y - 2Kb(1 - Kb)/Kg U - 2Kr(1 - Kr)/Kg V,  Kg = 1 - Kr - Kb
	B = Y + 2(1 - Kb) U

with Y in 0..1 and U, V in -0.5..0.5 once the range is undone: limited
("TV") range has Y in 16..235 and U, V in 16..240 of 255. A stream that
doesn't say is taken as BT.709 limited, which is what encoders make of
a screen at HD sizes.
*/
Yuv_Matrix yuv_matrix(const AVFrame *frame) {
	float kr = 0.2126f, kb = 0.0722f; // BT.709
	switch (frame->colorspace) {
	case AVCOL_SPC_BT470BG:
	case AVCOL_SPC_SMPTE170M:
	case AVCOL_SPC_FCC:
		kr = 0.299f, kb = 0.114f;
		break;
	case AVCOL_SPC_BT2020_NCL:
	case AVCOL_SPC_BT2020_CL:
		kr = 0.2627f, kb = 0.0593f;
		break;
	default:
		break;
	}
	float kg = 1.0f - kr - kb;
	bool full = frame->color_range == AVCOL_RANGE_JPEG;
	float ys = full ? 1.0f : 255.0f / 219.0f;
	float yo = full ? 0.0f : -16.0f / 255.0f * ys;
	float cs = full ? 1.0f : 255.0f / 224.0f;
	float co = -128.0f / 255.0f * cs;

	// Each row as a*y' + b*u' + c*v' with y' = ys*y + yo, u' = cs*u + co,
	// v' = cs*v + co, multiplied out.
	auto row = [&](float a, float b, float c) {
		return std::array<float, 4>{a * ys, b * cs, c * cs, a * yo + b * co + c * co};
	};
	std::array<float, 4> r = row(1, 0, 2 * (1 - kr));
	std::array<float, 4> g = row(1, -2 * kb * (1 - kb) / kg, -2 * kr * (1 - kr) / kg);
	std::array<float, 4> b = row(1, 2 * (1 - kb), 0);
	Yuv_Matrix m;
	memcpy(m.rows[0], r.data(), sizeof(m.rows[0]));
	memcpy(m.rows[1], g.data(), sizeof(m.rows[1]));
	memcpy(m.rows[2], b.data(), sizeof(m.rows[2]));
	return m;
}

bool software_only() {
	static bool off = [] {
		const char *v = getenv("YAP_VIDEO_SOFTWARE");
		return v && *v && strcmp(v, "0") != 0;
	}();
	return off;
}

Nv12::Nv12() : out_(av_frame_alloc()) {}

Nv12::~Nv12() {
	av_frame_free(&out_);
	sws_freeContext(sws_);
}

const AVFrame *Nv12::convert(const AVFrame *src) {
	if (src->format == AV_PIX_FMT_NV12) {
		return src;
	}
	if (out_->width != src->width || out_->height != src->height) {
		av_frame_unref(out_);
		out_->format = AV_PIX_FMT_NV12;
		out_->width = src->width;
		out_->height = src->height;
		if (av_frame_get_buffer(out_, 0) < 0) {
			av_frame_unref(out_);
			return nullptr;
		}
	}
	int cw = (src->width + 1) / 2, ch = (src->height + 1) / 2;
	if (src->format == AV_PIX_FMT_YUV420P || src->format == AV_PIX_FMT_YUVJ420P) {
		// What software decoders hand out nearly always: copy Y, and
		// weave U and V together, which is quicker than swscale's way.
		for (int y = 0; y < src->height; y++) {
			memcpy(out_->data[0] + y * out_->linesize[0], src->data[0] + y * src->linesize[0],
			       src->width);
		}
		for (int y = 0; y < ch; y++) {
			const uint8_t *u = src->data[1] + y * src->linesize[1];
			const uint8_t *v = src->data[2] + y * src->linesize[2];
			uint8_t *uv = out_->data[1] + y * out_->linesize[1];
			for (int x = 0; x < cw; x++) {
				uv[2 * x] = u[x];
				uv[2 * x + 1] = v[x];
			}
		}
	} else {
		sws_ = sws_getCachedContext(sws_, src->width, src->height,
		                            static_cast<AVPixelFormat>(src->format), src->width,
		                            src->height, AV_PIX_FMT_NV12, SWS_POINT, nullptr, nullptr,
		                            nullptr);
		if (!sws_ || sws_scale(sws_, src->data, src->linesize, 0, src->height, out_->data,
		                       out_->linesize) < 0) {
			return nullptr;
		}
	}
	out_->colorspace = src->colorspace;
	out_->color_range = src->color_range;
	return out_;
}

} // namespace yv
