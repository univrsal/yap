/*
Which encoders this computer has: every hardware encoder FFmpeg was built
with for this platform, each tried on a small test frame, because "the
driver says it exists" and "it opens and encodes" differ (an NVENC build
on a machine without NVIDIA, an AMD driver too old for AV1, ...). Last,
OpenH264 on the CPU, for machines where none of those work.
*/
#include "pipeline.h"

#include <algorithm>
#include <cstring>

#if defined(_WIN32)
#include <windows.h>
#elif !defined(__APPLE__)
#include "dl_linux.h"
#endif

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
	bool hardware = true;
};

// Best first: AV1 does most for screen content at a given bitrate, then
// HEVC, then H.264; any hardware encoder before the CPU's.
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
	// BSD, so it's in LGPL builds of FFmpeg (BtbN's have it; the macOS
	// one doesn't, and needn't: every Mac has VideoToolbox).
	{"libopenh264", YV_CODEC_H264, "OpenH264, on the CPU", false},
};

/*
The NVENC API version FFmpeg's NVENC encoders were built against, that
of the nv-codec-headers in our FFmpeg (scripts/ffmpeg.version), and the
first NVIDIA driver that has it. An older driver opens none of them.
*/
constexpr uint32_t NVENC_API_MAJOR = 13;
constexpr uint32_t NVENC_API_MINOR = 0;
constexpr int NVENC_DRIVER = 570;

// The newest NVENC API version the NVIDIA driver has, as
// (major << 4) | minor, or 0 if there's no NVIDIA driver.
uint32_t nvenc_driver_api() {
	// NVENCSTATUS NvEncodeAPIGetMaxSupportedVersion(uint32_t *version);
	using Get_Max = int (*)(uint32_t *);
	uint32_t version = 0;
#if defined(_WIN32)
	HMODULE lib = LoadLibraryExW(L"nvEncodeAPI64.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
	if (!lib) {
		return 0;
	}
	auto get = reinterpret_cast<Get_Max>(GetProcAddress(lib, "NvEncodeAPIGetMaxSupportedVersion"));
	if (!get || get(&version) != 0) {
		version = 0;
	}
	FreeLibrary(lib);
#elif !defined(__APPLE__)
	Dl_Lib lib;
	Get_Max get = nullptr;
	if (lib.open({"libnvidia-encode.so.1"})) {
		if (!lib.sym(get, "NvEncodeAPIGetMaxSupportedVersion") || get(&version) != 0) {
			version = 0;
		}
		dlclose(lib.handle);
	}
#endif
	return version;
}

/*
explain_nvenc says why, when FFmpeg has NVENC encoders and none of them
worked, if it's the driver being too old for them: FFmpeg says so too,
but it's quietened while trying (Quiet_FFmpeg), and "doesn't open"
alone leaves people guessing.
*/
void explain_nvenc(const std::vector<yv_encoder> &found) {
	bool tried = false;
	for (const yv_encoder &e : found) {
		if (strstr(e.name, "_nvenc")) {
			if (e.works) {
				return;
			}
			tried = true;
		}
	}
	if (!tried) {
		return;
	}
	uint32_t v = nvenc_driver_api();
	if (v == 0) {
		log(YV_LOG_DEBUG, "no NVIDIA driver, so no NVENC");
		return;
	}
	uint32_t major = v >> 4, minor = v & 0xf;
	if (major < NVENC_API_MAJOR || (major == NVENC_API_MAJOR && minor < NVENC_API_MINOR)) {
		log(YV_LOG_WARN,
		    "NVENC: the NVIDIA driver has NVENC API %u.%u, but this FFmpeg needs %u.%u; "
		    "update the driver to %d or later to encode on the GPU",
		    major, minor, NVENC_API_MAJOR, NVENC_API_MINOR, NVENC_DRIVER);
	}
}

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
and a pool of frames to upload the test frame into, and one that only
takes planar YUV (OpenH264) a copy in that. Returns the frame to encode,
which is `sw` itself when it takes it as it is.
*/
AVFrame *frame_for(AVCodecContext *enc, const AVCodec *codec, AVFrame *sw,
                   AVBufferRef **device) {
	if (takes_pix_fmt(codec, AV_PIX_FMT_NV12)) {
		enc->pix_fmt = AV_PIX_FMT_NV12;
		return sw;
	}
	if (takes_pix_fmt(codec, AV_PIX_FMT_YUV420P)) {
		enc->pix_fmt = AV_PIX_FMT_YUV420P;
		AVFrame *planar = av_frame_alloc();
		if (!planar || !nv12_to_i420(sw, planar)) {
			av_frame_free(&planar);
			return nullptr;
		}
		return planar;
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

bool nv12_to_i420(const AVFrame *src, AVFrame *dst) {
	av_frame_unref(dst);
	dst->format = AV_PIX_FMT_YUV420P;
	dst->width = src->width;
	dst->height = src->height;
	if (av_frame_get_buffer(dst, 0) < 0) {
		return false;
	}
	for (int y = 0; y < src->height; y++) {
		memcpy(dst->data[0] + y * dst->linesize[0], src->data[0] + y * src->linesize[0],
		       src->width);
	}
	int cw = (src->width + 1) / 2, ch = (src->height + 1) / 2;
	for (int y = 0; y < ch; y++) {
		const uint8_t *uv = src->data[1] + y * src->linesize[1];
		uint8_t *u = dst->data[1] + y * dst->linesize[1];
		uint8_t *v = dst->data[2] + y * dst->linesize[2];
		for (int x = 0; x < cw; x++) {
			u[x] = uv[2 * x];
			v[x] = uv[2 * x + 1];
		}
	}
	return av_frame_copy_props(dst, src) >= 0;
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
		e.hardware = c.hardware;
		e.works = can_try && try_encoder(codec);
		log(e.works ? YV_LOG_INFO : YV_LOG_DEBUG, "%s: %s", c.name,
		    e.works ? "works" : "doesn't open or encode");
		found.push_back(e);
	}
	explain_nvenc(found);
	// Working ones first, keeping the order of preference within each.
	std::stable_partition(found.begin(), found.end(), [](const yv_encoder &e) { return e.works; });
	return found;
}

} // namespace yv
