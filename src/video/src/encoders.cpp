/*
Which encoders this computer has: every hardware encoder FFmpeg was built
with for this platform, each tried on a small test frame, because "the
driver says it exists" and "it opens and encodes" differ (an NVENC build
on a machine without NVIDIA, an AMD driver too old for AV1, ...).
*/
#include "pipeline.h"

#include <algorithm>
#include <cstring>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
}

namespace yv {

namespace {

struct Candidate {
	const char *name;
	yv_codec codec;
	const char *vendor;
};

// Best first: AV1 does most for screen content at a given bitrate, then
// HEVC, then H.264. No software encoders yet (D5 in the plan).
const Candidate candidates[] = {
#if defined(_WIN32)
	{"av1_nvenc", YV_CODEC_AV1, "NVIDIA NVENC"},
	{"av1_amf", YV_CODEC_AV1, "AMD AMF"},
	{"av1_qsv", YV_CODEC_AV1, "Intel Quick Sync"},
	{"hevc_nvenc", YV_CODEC_HEVC, "NVIDIA NVENC"},
	{"hevc_amf", YV_CODEC_HEVC, "AMD AMF"},
	{"hevc_qsv", YV_CODEC_HEVC, "Intel Quick Sync"},
	{"h264_nvenc", YV_CODEC_H264, "NVIDIA NVENC"},
	{"h264_amf", YV_CODEC_H264, "AMD AMF"},
	{"h264_qsv", YV_CODEC_H264, "Intel Quick Sync"},
#elif defined(__APPLE__)
	{"hevc_videotoolbox", YV_CODEC_HEVC, "VideoToolbox"},
	{"h264_videotoolbox", YV_CODEC_H264, "VideoToolbox"},
#else
	{"av1_nvenc", YV_CODEC_AV1, "NVIDIA NVENC"},
	{"av1_vaapi", YV_CODEC_AV1, "VA-API"},
	{"hevc_nvenc", YV_CODEC_HEVC, "NVIDIA NVENC"},
	{"hevc_vaapi", YV_CODEC_HEVC, "VA-API"},
	{"h264_nvenc", YV_CODEC_H264, "NVIDIA NVENC"},
	{"h264_vaapi", YV_CODEC_H264, "VA-API"},
#endif
};

const char *codec_label(yv_codec c) {
	switch (c) {
	case YV_CODEC_H264:
		return "H.264";
	case YV_CODEC_HEVC:
		return "HEVC";
	case YV_CODEC_AV1:
		return "AV1";
	}
	return "?";
}

// The test frame: small, but over every encoder's minimum size.
constexpr int TEST_WIDTH = 640;
constexpr int TEST_HEIGHT = 480;

AVFrame *grey_nv12_frame() {
	AVFrame *f = av_frame_alloc();
	if (!f) {
		return nullptr;
	}
	f->format = AV_PIX_FMT_NV12;
	f->width = TEST_WIDTH;
	f->height = TEST_HEIGHT;
	if (av_frame_get_buffer(f, 0) < 0) {
		av_frame_free(&f);
		return nullptr;
	}
	for (int y = 0; y < TEST_HEIGHT; y++) {
		memset(f->data[0] + y * f->linesize[0], 128, TEST_WIDTH);
	}
	for (int y = 0; y < TEST_HEIGHT / 2; y++) {
		memset(f->data[1] + y * f->linesize[1], 128, TEST_WIDTH);
	}
	f->pts = 0;
	return f;
}

/*
An encoder that only takes frames in GPU memory (VA-API's) gets a device
and a pool of frames to upload the test frame into. Returns the frame
to encode, which is `sw` itself when no upload is needed.
*/
AVFrame *frame_for(AVCodecContext *enc, const AVCodec *codec, AVFrame *sw,
                   AVBufferRef **device) {
	if (takes_pix_fmt(codec, AV_PIX_FMT_NV12)) {
		enc->pix_fmt = AV_PIX_FMT_NV12;
		return sw;
	}
#if !defined(_WIN32) && !defined(__APPLE__)
	if (takes_pix_fmt(codec, AV_PIX_FMT_VAAPI)) {
		if (!vaapi_installed() ||
		    av_hwdevice_ctx_create(device, AV_HWDEVICE_TYPE_VAAPI, nullptr, nullptr, 0) < 0) {
			return nullptr;
		}
		AVBufferRef *frames = av_hwframe_ctx_alloc(*device);
		if (!frames) {
			return nullptr;
		}
		auto *fc = reinterpret_cast<AVHWFramesContext *>(frames->data);
		fc->format = AV_PIX_FMT_VAAPI;
		fc->sw_format = AV_PIX_FMT_NV12;
		fc->width = TEST_WIDTH;
		fc->height = TEST_HEIGHT;
		fc->initial_pool_size = 2;
		if (av_hwframe_ctx_init(frames) < 0) {
			av_buffer_unref(&frames);
			return nullptr;
		}
		enc->pix_fmt = AV_PIX_FMT_VAAPI;
		enc->hw_frames_ctx = frames; // the context owns it now
		AVFrame *hw = av_frame_alloc();
		if (!hw || av_hwframe_get_buffer(frames, hw, 0) < 0 ||
		    av_hwframe_transfer_data(hw, sw, 0) < 0) {
			av_frame_free(&hw);
			return nullptr;
		}
		hw->pts = sw->pts;
		return hw;
	}
#else
	(void)enc;
	(void)device;
#endif
	return nullptr;
}

// try_encoder opens `codec` and encodes one frame with it.
bool try_encoder(const AVCodec *codec) {
	Quiet_FFmpeg quiet;
	bool ok = false;
	AVCodecContext *enc = avcodec_alloc_context3(codec);
	AVFrame *sw = grey_nv12_frame();
	AVFrame *frame = nullptr;
	AVBufferRef *device = nullptr;
	AVPacket *pkt = av_packet_alloc();
	if (!enc || !sw || !pkt) {
		goto done;
	}
	enc->width = TEST_WIDTH;
	enc->height = TEST_HEIGHT;
	enc->time_base = {1, 60};
	enc->framerate = {60, 1};
	enc->bit_rate = 2'000'000;
	enc->max_b_frames = 0;
	enc->gop_size = 60;
	frame = frame_for(enc, codec, sw, &device);
	if (!frame || avcodec_open2(enc, codec, nullptr) < 0) {
		goto done;
	}
	if (avcodec_send_frame(enc, frame) < 0 || avcodec_send_frame(enc, nullptr) < 0) {
		goto done;
	}
	while (avcodec_receive_packet(enc, pkt) == 0) {
		if (pkt->size > 0) {
			ok = true;
		}
		av_packet_unref(pkt);
	}
done:
	if (frame != sw) {
		av_frame_free(&frame);
	}
	av_frame_free(&sw);
	av_packet_free(&pkt);
	avcodec_free_context(&enc);
	av_buffer_unref(&device);
	return ok;
}

} // namespace

bool takes_pix_fmt(const AVCodec *codec, int fmt) {
	const void *list = nullptr;
	int n = 0;
	if (avcodec_get_supported_config(nullptr, codec, AV_CODEC_CONFIG_PIX_FORMAT, 0, &list, &n) <
	        0 ||
	    !list) {
		// Nothing listed: it says it takes anything.
		return true;
	}
	auto *fmts = static_cast<const AVPixelFormat *>(list);
	for (int i = 0; i < n; i++) {
		if (fmts[i] == fmt) {
			return true;
		}
	}
	return false;
}

std::vector<yv_encoder> probe_encoders() {
	std::vector<yv_encoder> found;
	for (const Candidate &c : candidates) {
		const AVCodec *codec = avcodec_find_encoder_by_name(c.name);
		if (!codec) {
			log(YV_LOG_DEBUG, "%s: not in this FFmpeg", c.name);
			continue;
		}
		yv_encoder e{};
		copy_name(e.name, sizeof(e.name), c.name);
		// Opening a VA-API encoder at all needs libva (vaapi_installed).
		bool can_try = strstr(c.name, "_vaapi") == nullptr || vaapi_installed();
		copy_name(e.label, sizeof(e.label),
		          std::string(codec_label(c.codec)) + " (" + c.vendor + ")");
		e.codec = c.codec;
		e.hardware = true;
		e.works = can_try && try_encoder(codec);
		log(e.works ? YV_LOG_INFO : YV_LOG_DEBUG, "%s: %s", c.name,
		    e.works ? "works" : "doesn't open or encode");
		found.push_back(e);
	}
	// Working ones first, keeping the order of preference within each.
	std::stable_partition(found.begin(), found.end(), [](const yv_encoder &e) { return e.works; });
	return found;
}

} // namespace yv
