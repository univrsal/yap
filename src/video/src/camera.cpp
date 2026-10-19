/*
Cameras, the part that's the same on every platform (pipeline.h): which
of the camera's modes to open, and turning what it captures into the
NV12 frames share.cpp encodes.

The camera's frames come in on the platform's thread and wait, newest
only, for the share's thread. That decodes MJPEG (which most USB
cameras send at 720p and above) as each one comes, and scales and
converts to NV12 with swscale when one is encoded. Everything stays on
the CPU: at a camera's sizes that's a few percent of a core, and every
encoder takes frames from memory.

Cameras are BT.601 (JPEG's full range, raw YUV's limited); what's
encoded is BT.709 limited, like a screen.
*/
#include "pipeline.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <mutex>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>
}

namespace yv {

namespace {

using Clock = std::chrono::steady_clock;

// A camera opens at least this big and fast where it can, so that the room's
// tier can go up again later without opening it anew.
constexpr int CAPTURE_MIN_WIDTH = 1280;
constexpr int CAPTURE_MIN_HEIGHT = 720;
constexpr double CAPTURE_MIN_FPS = 30;
// No picture for this long means it was unplugged or another program took it;
// the first one can take longer, while the camera sets its exposure.
constexpr auto STALLED = std::chrono::seconds(5);
constexpr auto FIRST_STALLED = std::chrono::seconds(10);

const char *format_name(Camera_Format f) {
	switch (f) {
	case Camera_Format::NV12:
		return "NV12";
	case Camera_Format::I420:
		return "I420";
	case Camera_Format::YV12:
		return "YV12";
	case Camera_Format::YUY2:
		return "YUY2";
	case Camera_Format::UYVY:
		return "UYVY";
	case Camera_Format::YVYU:
		return "YVYU";
	case Camera_Format::BGRA:
		return "BGRA";
	case Camera_Format::BGRX:
		return "BGRX";
	case Camera_Format::BGR24:
		return "RGB24";
	case Camera_Format::GRAY:
		return "grey";
	case Camera_Format::MJPEG:
		return "MJPEG";
	case Camera_Format::OTHER:
		break;
	}
	return "?";
}

// How much a format is wanted, for modes that are otherwise alike: raw YUV is
// the least work, MJPEG has to be decoded first. 0 for one that can't be taken.
int format_rank(Camera_Format f) {
	switch (f) {
	case Camera_Format::NV12:
		return 6;
	case Camera_Format::I420:
	case Camera_Format::YV12:
	case Camera_Format::YUY2:
	case Camera_Format::UYVY:
	case Camera_Format::YVYU:
		return 5;
	case Camera_Format::MJPEG:
		return 4;
	case Camera_Format::BGRA:
	case Camera_Format::BGRX:
	case Camera_Format::BGR24:
		return 3;
	case Camera_Format::GRAY:
		return 1;
	case Camera_Format::OTHER:
		break;
	}
	return 0;
}

AVPixelFormat av_format(Camera_Format f) {
	switch (f) {
	case Camera_Format::NV12:
		return AV_PIX_FMT_NV12;
	case Camera_Format::I420:
	case Camera_Format::YV12: // with U and V the other way round
		return AV_PIX_FMT_YUV420P;
	case Camera_Format::YUY2:
		return AV_PIX_FMT_YUYV422;
	case Camera_Format::UYVY:
		return AV_PIX_FMT_UYVY422;
	case Camera_Format::YVYU:
		return AV_PIX_FMT_YVYU422;
	case Camera_Format::BGRA:
		return AV_PIX_FMT_BGRA;
	case Camera_Format::BGRX:
		return AV_PIX_FMT_BGR0;
	case Camera_Format::BGR24:
		return AV_PIX_FMT_BGR24;
	case Camera_Format::GRAY:
		return AV_PIX_FMT_GRAY8;
	case Camera_Format::MJPEG:
	case Camera_Format::OTHER:
		break;
	}
	return AV_PIX_FMT_NONE;
}

// JPEG's own pixel formats are the plain ones at full range.
AVPixelFormat without_j(AVPixelFormat f) {
	switch (f) {
	case AV_PIX_FMT_YUVJ420P:
		return AV_PIX_FMT_YUV420P;
	case AV_PIX_FMT_YUVJ422P:
		return AV_PIX_FMT_YUV422P;
	case AV_PIX_FMT_YUVJ444P:
		return AV_PIX_FMT_YUV444P;
	case AV_PIX_FMT_YUVJ440P:
		return AV_PIX_FMT_YUV440P;
	case AV_PIX_FMT_YUVJ411P:
		return AV_PIX_FMT_YUV411P;
	default:
		return f;
	}
}

// The size nearest `want` in lo..hi, on the steps from lo.
int in_steps(int want, int lo, int hi, int step) {
	int v = std::clamp(want, lo, std::max(lo, hi));
	if (step > 1) {
		v = lo + (v - lo) / step * step;
	}
	return v;
}

struct Choice {
	Camera_Mode mode;
	int width = 0, height = 0;
	double fps = 0;
};

/*
better says whether `a` is the better way to capture `want_w` x `want_h` at
`want_fps` than `b`: one that keeps up first, then one that's big enough
(the smallest of those) or else the biggest, then the cheaper format, then
the faster.
*/
bool better(const Choice &a, const Choice &b, int want_w, int want_h, double want_fps) {
	bool a_fast = a.fps >= want_fps - 0.5, b_fast = b.fps >= want_fps - 0.5;
	if (a_fast != b_fast) {
		return a_fast;
	}
	bool a_big = a.width >= want_w && a.height >= want_h;
	bool b_big = b.width >= want_w && b.height >= want_h;
	if (a_big != b_big) {
		return a_big;
	}
	int64_t a_area = static_cast<int64_t>(a.width) * a.height;
	int64_t b_area = static_cast<int64_t>(b.width) * b.height;
	if (a_area != b_area) {
		return a_big ? a_area < b_area : a_area > b_area;
	}
	int a_rank = format_rank(a.mode.format), b_rank = format_rank(b.mode.format);
	if (a_rank != b_rank) {
		return a_rank > b_rank;
	}
	return a.fps > b.fps;
}

bool choose_mode(const std::vector<Camera_Mode> &modes, int want_w, int want_h, double want_fps,
                 Choice &out) {
	bool found = false;
	for (const Camera_Mode &m : modes) {
		if (format_rank(m.format) == 0 || m.max_width <= 0 || m.max_height <= 0) {
			continue;
		}
		Choice c;
		c.mode = m;
		c.width = in_steps(want_w, m.min_width, m.max_width, m.step_width);
		c.height = in_steps(want_h, m.min_height, m.max_height, m.step_height);
		c.fps = m.max_fps > 0 ? std::min(want_fps, m.max_fps) : want_fps;
		c.fps = std::max(c.fps, m.min_fps);
		if (!found || better(c, out, want_w, want_h, want_fps)) {
			out = c;
			found = true;
		}
	}
	return found;
}

// A frame as it came from the camera, with room after it for FFmpeg's
// decoders to read past the end.
struct Raw {
	std::vector<uint8_t> data;
	size_t size = 0;
	Camera_Format format = Camera_Format::OTHER;
	int width = 0, height = 0;
	bool flip = false;
};

class Camera_Pipeline final : public Pipeline, public Camera_Sink {
public:
	explicit Camera_Pipeline(std::string id) : id_(std::move(id)) {}

	~Camera_Pipeline() override {
		// No more frames once it's gone.
		source_.reset();
		sws_freeContext(sws_);
		avcodec_free_context(&mjpeg_);
		av_frame_free(&decoded_);
		av_packet_free(&pkt_);
	}

	bool open(const yv_share_config &config, const char *, const std::atomic<bool> &,
	          std::string &error) override {
		if (!camera_allowed(false)) {
#ifdef _WIN32
			error = "Windows doesn't let apps use the camera: turn it on in Settings, "
			        "Privacy & security, Camera (and \"Let desktop apps access your camera\")";
#else
			error = "the system doesn't let yap use the camera";
#endif
			return false;
		}
		std::vector<Camera_Info> cameras = list_cameras();
		const Camera_Info *cam = nullptr;
		for (const Camera_Info &c : cameras) {
			if (id_.empty() || id_ == c.camera.id) {
				cam = &c;
				break;
			}
		}
		if (!cam) {
			error = cameras.empty() ? "there's no camera" : "that camera isn't there any more";
			return false;
		}
		for (const Camera_Mode &m : cam->modes) {
			log(YV_LOG_DEBUG, "camera: %s has %dx%d to %dx%d, %s, %.1f to %.1f fps", cam->camera.name,
			    m.min_width, m.min_height, m.max_width, m.max_height, format_name(m.format),
			    m.min_fps, m.max_fps);
		}
		int want_w = config.max_width > 0 ? std::max(config.max_width, CAPTURE_MIN_WIDTH) : 1920;
		int want_h = config.max_height > 0 ? std::max(config.max_height, CAPTURE_MIN_HEIGHT) : 1080;
		double want_fps = std::max(static_cast<double>(config.fps), CAPTURE_MIN_FPS);
		Choice choice;
		if (!choose_mode(cam->modes, want_w, want_h, want_fps, choice)) {
			error = "the camera sends nothing yap can take";
			return false;
		}
		source_ = make_camera_source();
		if (!source_) {
			error = "cameras can't be used here";
			return false;
		}
		log(YV_LOG_INFO, "camera: opening %s at %dx%d %s, %.0f fps", cam->camera.name, choice.width,
		    choice.height, format_name(choice.mode.format), choice.fps);
		if (!source_->open(*cam, choice.mode, choice.width, choice.height, choice.fps, *this,
		                   error)) {
			source_.reset();
			return false;
		}
		opened_at_ = Clock::now();
		return true;
	}

	void frame(const Camera_Frame &f) override {
		if (!told_first_) {
			told_first_ = true;
			log(YV_LOG_DEBUG, "camera: the first picture is %dx%d %s, %zu bytes%s", f.width,
			    f.height, format_name(f.format), f.size, f.flip ? ", bottom up" : "");
		}
		if (f.width <= 0 || f.height <= 0 || !f.data || f.size == 0) {
			return;
		}
		spare_.data.resize(f.size + AV_INPUT_BUFFER_PADDING_SIZE);
		memcpy(spare_.data.data(), f.data, f.size);
		memset(spare_.data.data() + f.size, 0, AV_INPUT_BUFFER_PADDING_SIZE);
		spare_.size = f.size;
		spare_.format = f.format;
		spare_.width = f.width;
		spare_.height = f.height;
		spare_.flip = f.flip;
		{
			std::lock_guard<std::mutex> lock(mutex_);
			std::swap(spare_, incoming_);
			fresh_ = true;
		}
		wake_.notify_one();
	}

	bool wait(int ms, bool &closed) override {
		closed = false;
		bool got = false;
		{
			std::unique_lock<std::mutex> lock(mutex_);
			wake_.wait_for(lock, std::chrono::milliseconds(ms), [this] { return fresh_; });
			if (fresh_) {
				std::swap(incoming_, current_);
				fresh_ = false;
				got = true;
			}
		}
		Clock::time_point now = Clock::now();
		// A frame that can't be taken (a broken JPEG) is as if none came.
		if (got && take(current_)) {
			last_at_ = now;
			have_ = true;
			return true;
		}
		Clock::time_point since = have_ ? last_at_ : opened_at_;
		closed = now - since > (have_ ? STALLED : FIRST_STALLED);
		return false;
	}

	int width() override {
		return src_w_;
	}

	int height() override {
		return src_h_;
	}

	AVBufferRef *hw_device() override {
		return nullptr;
	}

	AVBufferRef *hw_frames(int, int) override {
		return nullptr;
	}

	bool convert(AVFrame *out, AVBufferRef *, int w, int h) override {
		if (src_w_ == 0) {
			return false;
		}
		out->format = AV_PIX_FMT_NV12;
		out->width = w;
		out->height = h;
		if (av_frame_get_buffer(out, 0) < 0) {
			return false;
		}
		SwsContext *sws = sws_getCachedContext(sws_, src_w_, src_h_, src_format_, w, h,
		                                       AV_PIX_FMT_NV12, SWS_BICUBIC, nullptr, nullptr,
		                                       nullptr);
		if (!sws) {
			return false;
		}
		// A new context starts with swscale's own colours.
		if (sws != sws_ || src_full_ != sws_full_) {
			const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(src_format_);
			bool rgb = d && (d->flags & AV_PIX_FMT_FLAG_RGB);
			sws_setColorspaceDetails(sws, sws_getCoefficients(rgb ? SWS_CS_DEFAULT : SWS_CS_ITU601),
			                         src_full_ ? 1 : 0, sws_getCoefficients(SWS_CS_ITU709), 0, 0,
			                         1 << 16, 1 << 16);
			sws_ = sws;
			sws_full_ = src_full_;
		}
		sws_scale(sws_, src_data_, src_linesize_, 0, src_h_, out->data, out->linesize);
		return true;
	}

	std::string gone() override {
		return have_ ? "the camera stopped sending pictures (unplugged, or another program took it)"
		             : "the camera didn't send any pictures";
	}

private:
	std::string id_;
	std::unique_ptr<Camera_Source> source_;
	Clock::time_point opened_at_, last_at_;
	bool have_ = false;

	// The camera's thread fills spare_ and swaps it with incoming_; the share's
	// takes incoming_ into current_, and what it takes, shown_ (or decoded_)
	// is what convert reads.
	std::mutex mutex_;
	std::condition_variable wake_;
	bool fresh_ = false;
	Raw spare_, incoming_, current_, shown_;
	bool told_first_ = false; // the camera's thread's

	AVCodecContext *mjpeg_ = nullptr;
	bool mjpeg_failed_ = false;
	AVFrame *decoded_ = nullptr;
	AVPacket *pkt_ = nullptr;

	// The newest picture, for convert.
	const uint8_t *src_data_[4] = {};
	int src_linesize_[4] = {};
	AVPixelFormat src_format_ = AV_PIX_FMT_NONE;
	int src_w_ = 0, src_h_ = 0;
	bool src_full_ = false;

	SwsContext *sws_ = nullptr;
	bool sws_full_ = false;

	bool take(Raw &r) {
		if (r.format == Camera_Format::MJPEG) {
			return decode(r);
		}
		// libdshowcapture calls RGB24 XRGB too, which Windows usually converts on
		// the way but not always (wine): three bytes a pixel are RGB24 whatever
		// they're called.
		size_t pixels = static_cast<size_t>(r.width) * static_cast<size_t>(r.height);
		if ((r.format == Camera_Format::BGRX || r.format == Camera_Format::BGRA) &&
		    r.size >= pixels * 3 && r.size < pixels * 4) {
			r.format = Camera_Format::BGR24;
		}
		AVPixelFormat fmt = av_format(r.format);
		if (fmt == AV_PIX_FMT_NONE) {
			return false;
		}
		uint8_t *data[4] = {};
		int linesize[4] = {};
		if (av_pix_fmt_count_planes(fmt) == 1) {
			// Rows may be padded (RGB rows to four bytes): the size says how.
			int min = av_image_get_linesize(fmt, r.width, 0);
			int stride = static_cast<int>(r.size / static_cast<size_t>(r.height));
			if (min <= 0 || stride < min) {
				return false;
			}
			data[0] = r.data.data();
			linesize[0] = stride;
			if (r.flip) {
				data[0] += static_cast<ptrdiff_t>(stride) * (r.height - 1);
				linesize[0] = -stride;
			}
		} else {
			int need = av_image_fill_arrays(data, linesize, r.data.data(), fmt, r.width, r.height, 1);
			if (need < 0 || r.size < static_cast<size_t>(need)) {
				return false;
			}
			if (r.format == Camera_Format::YV12) {
				std::swap(data[1], data[2]);
			}
		}
		// What convert reads stays where it is until the next one is taken.
		std::swap(r, shown_);
		for (int i = 0; i < 4; i++) {
			src_data_[i] = data[i];
			src_linesize_[i] = linesize[i];
		}
		src_format_ = fmt;
		src_w_ = shown_.width;
		src_h_ = shown_.height;
		src_full_ = shown_.format == Camera_Format::BGRA || shown_.format == Camera_Format::BGRX ||
		            shown_.format == Camera_Format::BGR24 || shown_.format == Camera_Format::GRAY;
		return true;
	}

	bool decode(const Raw &r) {
		if (!mjpeg_ && !open_mjpeg()) {
			return false;
		}
		pkt_->data = const_cast<uint8_t *>(r.data.data());
		pkt_->size = static_cast<int>(r.size);
		int err = avcodec_send_packet(mjpeg_, pkt_);
		pkt_->data = nullptr;
		pkt_->size = 0;
		if (err < 0) {
			return false;
		}
		AVFrame *f = av_frame_alloc();
		if (!f || avcodec_receive_frame(mjpeg_, f) < 0) {
			av_frame_free(&f);
			return false;
		}
		av_frame_free(&decoded_);
		decoded_ = f;
		AVPixelFormat fmt = static_cast<AVPixelFormat>(f->format);
		for (int i = 0; i < 4; i++) {
			src_data_[i] = f->data[i];
			src_linesize_[i] = f->linesize[i];
		}
		src_format_ = without_j(fmt);
		src_w_ = f->width;
		src_h_ = f->height;
		src_full_ = fmt != src_format_ || f->color_range != AVCOL_RANGE_MPEG;
		return true;
	}

	bool open_mjpeg() {
		if (mjpeg_failed_) {
			return false;
		}
		const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_MJPEG);
		mjpeg_ = codec ? avcodec_alloc_context3(codec) : nullptr;
		pkt_ = pkt_ ? pkt_ : av_packet_alloc();
		if (mjpeg_) {
			mjpeg_->flags |= AV_CODEC_FLAG_LOW_DELAY;
			mjpeg_->thread_count = 1;
		}
		if (!mjpeg_ || !pkt_ || avcodec_open2(mjpeg_, codec, nullptr) < 0) {
			log(YV_LOG_ERROR, "camera: this FFmpeg can't decode MJPEG");
			avcodec_free_context(&mjpeg_);
			mjpeg_failed_ = true;
			return false;
		}
		return true;
	}
};

} // namespace

std::unique_ptr<Pipeline> make_camera_pipeline(const std::string &id) {
	return std::make_unique<Camera_Pipeline>(id);
}

} // namespace yv
