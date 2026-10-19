/*
Watching: a view's decoder thread, and what it's fed with. The network
thread pushes whole frames; they wait in a short queue, so a slow
decoder never holds the network up. A queue that grows anyway means the
decoder can't keep up, which is a failure like any other: everything
waiting is dropped and the decoder waits for a keyframe.

Hardware decoding where the output's device does the codec, software
otherwise: FFmpeg's H.264 and HEVC decoders fall back by themselves when
the hardware won't (get_format is asked again without it), and AV1
goes to dav1d, since FFmpeg's own AV1 decoder only drives hardware.
*/
#include "output.h"

#include <condition_variable>
#include <deque>
#include <thread>

#include "ffmpeg.h"

namespace yv {

namespace {

// Frames waiting for the decoder; more means it can't keep up. A few
// frames at 60fps is already more delay than is worth showing.
constexpr size_t MAX_QUEUED = 8;

struct Packet {
	std::vector<uint8_t> data;
	yv_codec codec;
	uint64_t pts_us;
	bool key;
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

/*
pick_format takes the hardware format where it's offered, the decoder's
own first choice otherwise. When the hardware turns out not to do this
stream after all, FFmpeg asks again without it.
*/
AVPixelFormat pick_format(AVCodecContext *dec, const AVPixelFormat *fmts) {
	AVPixelFormat hw = *static_cast<AVPixelFormat *>(dec->opaque);
	for (const AVPixelFormat *f = fmts; *f != AV_PIX_FMT_NONE; f++) {
		if (*f == hw) {
			return hw;
		}
	}
	for (const AVPixelFormat *f = fmts; *f != AV_PIX_FMT_NONE; f++) {
		if (!(av_pix_fmt_desc_get(*f)->flags & AV_PIX_FMT_FLAG_HWACCEL)) {
			return *f;
		}
	}
	return AV_PIX_FMT_NONE;
}

} // namespace

} // namespace yv

struct yv_view {
	yv_context *ctx = nullptr;
	std::unique_ptr<yv::Output> output;

	std::mutex mutex;
	std::condition_variable wake;
	std::deque<yv::Packet> queue;
	bool quit = false;
	bool clear = false;  // drop the decoder, the queue and the picture
	bool failed = false; // for yv_view_take_failed

	// yv_view_on_frame's, under its own lock so a call doesn't wait for
	// the queue.
	std::mutex on_frame_mutex;
	yv_frame_fn on_frame = nullptr;
	void *on_frame_user = nullptr;

	// The decoder thread's own.
	std::thread thread;
	AVCodecContext *dec = nullptr;
	yv_codec codec = YV_CODEC_H264;
	AVPixelFormat hw_format = AV_PIX_FMT_NONE; // pick_format's opaque
	bool need_key = true;
	AVFrame *frame = nullptr;
	AVPacket *pkt = nullptr;
};

namespace yv {

namespace {

void close_decoder(yv_view *v) {
	avcodec_free_context(&v->dec);
}

// fail drops the decoder, which then waits for a keyframe, and says so.
void fail(yv_view *v, const char *why) {
	log(YV_LOG_WARN, "video: %s; waiting for a keyframe", why);
	close_decoder(v);
	v->need_key = true;
	std::lock_guard<std::mutex> lock(v->mutex);
	v->failed = true;
}

AVPixelFormat hw_pix_fmt(const AVCodec *codec, AVBufferRef *device) {
	auto type = reinterpret_cast<AVHWDeviceContext *>(device->data)->type;
	for (int i = 0;; i++) {
		const AVCodecHWConfig *cfg = avcodec_get_hw_config(codec, i);
		if (!cfg) {
			return AV_PIX_FMT_NONE;
		}
		if ((cfg->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) && cfg->device_type == type) {
			return cfg->pix_fmt;
		}
	}
}

bool open_decoder(yv_view *v, yv_codec codec) {
	close_decoder(v);
	v->codec = codec;
	AVBufferRef *device = v->output->hw_device();
	const char *name = nullptr;
	bool use_device = device != nullptr;
	switch (codec) {
	case YV_CODEC_H264:
		name = "h264";
		break;
	case YV_CODEC_HEVC:
		name = "hevc";
		break;
	case YV_CODEC_AV1:
		// FFmpeg's own decoder may not be built in (decodable_codecs).
		use_device = use_device && v->output->hw_decodes(codec) &&
		             avcodec_find_decoder_by_name("av1");
		name = use_device ? "av1" : "libdav1d";
		break;
	}
	const AVCodec *dec = avcodec_find_decoder_by_name(name);
	if (!dec) {
		log(YV_LOG_ERROR, "video: this FFmpeg has no %s decoder", name);
		av_buffer_unref(&device);
		return false;
	}
	v->dec = avcodec_alloc_context3(dec);
	v->dec->flags |= AV_CODEC_FLAG_LOW_DELAY;
	// Slices, not frames, in parallel: frame threads would hold back as
	// many frames as there are threads.
	v->dec->thread_type = FF_THREAD_SLICE;
	v->dec->thread_count = 0;
	v->hw_format = AV_PIX_FMT_NONE;
	if (use_device) {
		v->hw_format = hw_pix_fmt(dec, device);
		if (v->hw_format != AV_PIX_FMT_NONE) {
			v->dec->hw_device_ctx = av_buffer_ref(device);
			v->dec->opaque = &v->hw_format;
			v->dec->get_format = pick_format;
			// Room for the frames the output holds on to while it draws
			// from them on the GPU (gl_interop.h), so the decoder never
			// runs short of surfaces.
			v->dec->extra_hw_frames = 3;
		}
	}
	av_buffer_unref(&device);
	AVDictionary *opts = nullptr;
	if (strcmp(name, "libdav1d") == 0) {
		// Hand each frame out as soon as it's decoded.
		av_dict_set(&opts, "max_frame_delay", "1", 0);
	}
	int err = avcodec_open2(v->dec, dec, &opts);
	av_dict_free(&opts);
	if (err < 0) {
		log(YV_LOG_ERROR, "video: can't open the %s decoder (%d)", name, err);
		close_decoder(v);
		return false;
	}
	log(YV_LOG_INFO, "video: decoding %s with %s%s", codec_label(codec), name,
	    v->hw_format != AV_PIX_FMT_NONE ? " on the GPU" : "");
	return true;
}

void decode(yv_view *v, Packet &p) {
	if (v->output->device_stale()) {
		close_decoder(v);
		v->output->renew_device();
		if (!p.key) {
			fail(v, "the GPU changed");
			return;
		}
	}
	if (v->dec && p.codec != v->codec) {
		close_decoder(v);
		v->need_key = true;
	}
	if (v->need_key) {
		if (!p.key) {
			return;
		}
		v->need_key = false;
	}
	if (!v->dec && !open_decoder(v, p.codec)) {
		fail(v, "no decoder");
		return;
	}
	v->pkt->data = p.data.data();
	v->pkt->size = static_cast<int>(p.data.size());
	v->pkt->pts = static_cast<int64_t>(p.pts_us);
	v->pkt->flags = p.key ? AV_PKT_FLAG_KEY : 0;
	int err = avcodec_send_packet(v->dec, v->pkt);
	v->pkt->data = nullptr;
	v->pkt->size = 0;
	if (err < 0 && err != AVERROR(EAGAIN)) {
		fail(v, "the decoder refused a frame");
		return;
	}
	for (;;) {
		err = avcodec_receive_frame(v->dec, v->frame);
		if (err == AVERROR(EAGAIN) || err == AVERROR_EOF) {
			break;
		}
		if (err < 0) {
			fail(v, "a frame didn't decode");
			return;
		}
		bool ok = v->output->submit(v->frame);
		av_frame_unref(v->frame);
		if (!ok) {
			fail(v, "a decoded frame couldn't be shown");
			return;
		}
		std::lock_guard<std::mutex> lock(v->on_frame_mutex);
		if (v->on_frame) {
			v->on_frame(v->on_frame_user);
		}
	}
}

void run(yv_view *v) {
	for (;;) {
		Packet p;
		{
			std::unique_lock<std::mutex> lock(v->mutex);
			v->wake.wait(lock, [v] { return v->quit || v->clear || !v->queue.empty(); });
			if (v->quit) {
				break;
			}
			if (v->clear) {
				// Whoever asked has emptied the queue of what came before.
				v->clear = false;
				lock.unlock();
				close_decoder(v);
				v->need_key = true;
				continue;
			}
			p = std::move(v->queue.front());
			v->queue.pop_front();
		}
		decode(v, p);
	}
	close_decoder(v);
}

} // namespace

void view_set_gpu(yv_view *v, const yv_gpu *gpu, uint64_t luid) {
	v->output->set_gpu(gpu, luid);
}

/*
FFmpeg from the system may be built without some decoders (Fedora's
ffmpeg-free has no H.264 or HEVC, some have no dav1d), and what it
can't decode mustn't be asked of it. AV1 counts only with dav1d:
FFmpeg's own decoder needs hardware, which isn't known until there's a
GPU, and isn't everyone's.
*/
uint32_t decodable_codecs() {
	static const uint32_t codecs = [] {
		uint32_t bits = 0;
		for (yv_codec c : {YV_CODEC_H264, YV_CODEC_HEVC, YV_CODEC_AV1}) {
			const char *name = c == YV_CODEC_H264 ? "h264" : c == YV_CODEC_HEVC ? "hevc" : "libdav1d";
			if (avcodec_find_decoder_by_name(name)) {
				bits |= 1u << c;
			} else {
				log(YV_LOG_WARN, "video: this FFmpeg has no %s decoder, so no watching %s", name,
				    codec_label(c));
			}
		}
		return bits;
	}();
	return codecs;
}

} // namespace yv

extern "C" {

YV_API yv_view *yv_view_create(yv_context *ctx) {
	if (!ctx) {
		return nullptr;
	}
	auto *v = new yv_view;
	v->ctx = ctx;
	v->output = yv::make_output();
	v->frame = av_frame_alloc();
	v->pkt = av_packet_alloc();
	{
		std::lock_guard<std::mutex> lock(ctx->views_mutex);
		ctx->views.push_back(v);
		v->output->set_gpu(&ctx->gpu, ctx->gpu_luid);
	}
	v->thread = std::thread(yv::run, v);
	return v;
}

YV_API void yv_view_destroy(yv_view *v) {
	if (!v) {
		return;
	}
	{
		std::lock_guard<std::mutex> lock(v->mutex);
		v->quit = true;
	}
	v->wake.notify_one();
	v->thread.join();
	{
		std::lock_guard<std::mutex> lock(v->ctx->views_mutex);
		std::erase(v->ctx->views, v);
	}
	av_frame_free(&v->frame);
	av_packet_free(&v->pkt);
	delete v;
}

YV_API void yv_view_push(yv_view *v, const uint8_t *data, size_t size, yv_codec codec,
                         uint64_t pts_us, bool key) {
	if (!v || !data || size == 0) {
		return;
	}
	yv::Packet p{std::vector<uint8_t>(data, data + size), codec, pts_us, key};
	bool overflow = false;
	{
		std::lock_guard<std::mutex> lock(v->mutex);
		if (v->queue.size() >= yv::MAX_QUEUED) {
			// What's queued is too late to be worth showing, and what
			// follows depends on it: start again from a keyframe.
			v->queue.clear();
			v->clear = true;
			v->failed = true;
			overflow = true;
		}
		v->queue.push_back(std::move(p));
	}
	if (overflow) {
		yv::log(YV_LOG_WARN, "video: the decoder can't keep up");
	}
	v->wake.notify_one();
}

YV_API void yv_view_clear(yv_view *v) {
	if (!v) {
		return;
	}
	{
		std::lock_guard<std::mutex> lock(v->mutex);
		v->queue.clear();
		v->clear = true;
		v->failed = false;
	}
	v->output->clear();
	v->wake.notify_one();
}

YV_API void yv_view_on_frame(yv_view *v, yv_frame_fn fn, void *user) {
	if (!v) {
		return;
	}
	std::lock_guard<std::mutex> lock(v->on_frame_mutex);
	v->on_frame = fn;
	v->on_frame_user = user;
}

YV_API bool yv_view_take_failed(yv_view *v) {
	if (!v) {
		return false;
	}
	std::lock_guard<std::mutex> lock(v->mutex);
	bool f = v->failed;
	v->failed = false;
	return f;
}

YV_API bool yv_view_present(yv_view *v, yv_picture *out) {
	if (!v || !out) {
		return false;
	}
	*out = {};
	return v->output->present(out);
}

} // extern "C"
