/*
A made-up camera, on Linux and macOS.

For trying everything after the camera without one, as Chromium's
--use-fake-device-for-media-stream does, YAP_VIDEO_FAKE_CAMERA=1 in the
environment makes one up: 1280x720 at 30 fps of colour bars with a box
going round, sent as YUY2, or as YAP_VIDEO_FAKE_CAMERA says: nv12, bgrx
(bottom up, as Windows' RGB is) or mjpeg.
*/
#include "pipeline.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <thread>

extern "C" {
#include <libavcodec/avcodec.h>
}

namespace yv {

namespace {

constexpr int FAKE_WIDTH = 1280, FAKE_HEIGHT = 720, FAKE_FPS = 30;

Camera_Format fake_format() {
	const char *v = getenv("YAP_VIDEO_FAKE_CAMERA");
	if (!v || !*v || strcmp(v, "0") == 0) {
		return Camera_Format::OTHER;
	}
	if (strcmp(v, "nv12") == 0) {
		return Camera_Format::NV12;
	}
	if (strcmp(v, "bgrx") == 0) {
		return Camera_Format::BGRX;
	}
	if (strcmp(v, "mjpeg") == 0) {
		return Camera_Format::MJPEG;
	}
	return Camera_Format::YUY2;
}

// The bars, left to right, as RGB: white, yellow, cyan, green, magenta,
// red, blue, black; the box is white.
const uint8_t BARS[8][3] = {{235, 235, 235}, {235, 235, 16}, {16, 235, 235}, {16, 235, 16},
                            {235, 16, 235},  {235, 16, 16},  {16, 16, 235},  {16, 16, 16}};

// BT.601 limited, as cameras are.
void yuv_of(const uint8_t rgb[3], uint8_t &y, uint8_t &u, uint8_t &v) {
	double r = rgb[0], g = rgb[1], b = rgb[2];
	double yy = 0.299 * r + 0.587 * g + 0.114 * b;
	y = static_cast<uint8_t>(16 + (yy - 16) * 219.0 / 219.0);
	u = static_cast<uint8_t>(std::clamp(128 + (b - yy) / 1.772 * 224.0 / 219.0, 16.0, 240.0));
	v = static_cast<uint8_t>(std::clamp(128 + (r - yy) / 1.402 * 224.0 / 219.0, 16.0, 240.0));
}

const uint8_t *colour_at(int x, int y, int frame) {
	static const uint8_t WHITE[3] = {235, 235, 235};
	int bx = (frame * 8) % (FAKE_WIDTH - 160), by = FAKE_HEIGHT - 200;
	if (x >= bx && x < bx + 160 && y >= by && y < by + 160) {
		return WHITE;
	}
	return BARS[x * 8 / FAKE_WIDTH];
}

class Fake_Source final : public Camera_Source {
public:
	~Fake_Source() override {
		quit_.store(true);
		if (thread_.joinable()) {
			thread_.join();
		}
		avcodec_free_context(&jpeg_);
		av_frame_free(&yuv_);
		av_packet_free(&pkt_);
	}

	bool open(const Camera_Info &, const Camera_Mode &mode, int, int, double, Camera_Sink &sink,
	          std::string &error) override {
		format_ = mode.format;
		if (format_ == Camera_Format::MJPEG && !open_jpeg()) {
			error = "this FFmpeg can't make MJPEG";
			return false;
		}
		thread_ = std::thread([this, &sink] { run(sink); });
		return true;
	}

private:
	Camera_Format format_ = Camera_Format::YUY2;
	std::atomic<bool> quit_{false};
	std::thread thread_;
	std::vector<uint8_t> buf_;
	AVCodecContext *jpeg_ = nullptr;
	AVFrame *yuv_ = nullptr;
	AVPacket *pkt_ = nullptr;

	bool open_jpeg() {
		const AVCodec *c = avcodec_find_encoder(AV_CODEC_ID_MJPEG);
		if (!c) {
			return false;
		}
		jpeg_ = avcodec_alloc_context3(c);
		jpeg_->width = FAKE_WIDTH;
		jpeg_->height = FAKE_HEIGHT;
		jpeg_->time_base = {1, FAKE_FPS};
		jpeg_->pix_fmt = AV_PIX_FMT_YUVJ422P;
		jpeg_->color_range = AVCOL_RANGE_JPEG;
		yuv_ = av_frame_alloc();
		pkt_ = av_packet_alloc();
		yuv_->format = AV_PIX_FMT_YUVJ422P;
		yuv_->width = FAKE_WIDTH;
		yuv_->height = FAKE_HEIGHT;
		return avcodec_open2(jpeg_, c, nullptr) >= 0 && av_frame_get_buffer(yuv_, 0) >= 0;
	}

	void draw(int frame) {
		const int w = FAKE_WIDTH, h = FAKE_HEIGHT;
		switch (format_) {
		case Camera_Format::NV12:
			buf_.resize(static_cast<size_t>(w) * h * 3 / 2);
			for (int y = 0; y < h; y++) {
				for (int x = 0; x < w; x++) {
					uint8_t yy, u, v;
					yuv_of(colour_at(x, y, frame), yy, u, v);
					buf_[static_cast<size_t>(y) * w + x] = yy;
					if (y % 2 == 0 && x % 2 == 0) {
						size_t at = static_cast<size_t>(w) * h + static_cast<size_t>(y / 2) * w + x;
						buf_[at] = u;
						buf_[at + 1] = v;
					}
				}
			}
			break;
		case Camera_Format::BGRX:
			buf_.resize(static_cast<size_t>(w) * h * 4);
			for (int y = 0; y < h; y++) {
				// Bottom up.
				uint8_t *row = buf_.data() + static_cast<size_t>(h - 1 - y) * w * 4;
				for (int x = 0; x < w; x++) {
					const uint8_t *c = colour_at(x, y, frame);
					row[x * 4] = c[2];
					row[x * 4 + 1] = c[1];
					row[x * 4 + 2] = c[0];
					row[x * 4 + 3] = 255;
				}
			}
			break;
		case Camera_Format::MJPEG: {
			av_frame_make_writable(yuv_);
			for (int y = 0; y < h; y++) {
				for (int x = 0; x < w; x++) {
					uint8_t yy, u, v;
					yuv_of(colour_at(x, y, frame), yy, u, v);
					// Full range, as JPEG is.
					yuv_->data[0][y * yuv_->linesize[0] + x] =
						static_cast<uint8_t>(std::clamp((yy - 16) * 255 / 219, 0, 255));
					if (x % 2 == 0) {
						yuv_->data[1][y * yuv_->linesize[1] + x / 2] =
							static_cast<uint8_t>(std::clamp((u - 128) * 255 / 224 + 128, 0, 255));
						yuv_->data[2][y * yuv_->linesize[2] + x / 2] =
							static_cast<uint8_t>(std::clamp((v - 128) * 255 / 224 + 128, 0, 255));
					}
				}
			}
			yuv_->pts = frame;
			buf_.clear();
			if (avcodec_send_frame(jpeg_, yuv_) >= 0 && avcodec_receive_packet(jpeg_, pkt_) >= 0) {
				buf_.assign(pkt_->data, pkt_->data + pkt_->size);
				av_packet_unref(pkt_);
			}
			break;
		}
		default: // YUY2
			buf_.resize(static_cast<size_t>(w) * h * 2);
			for (int y = 0; y < h; y++) {
				for (int x = 0; x < w; x += 2) {
					uint8_t y0, y1, u, v;
					yuv_of(colour_at(x, y, frame), y0, u, v);
					yuv_of(colour_at(x + 1, y, frame), y1, u, v);
					uint8_t *p = buf_.data() + (static_cast<size_t>(y) * w + x) * 2;
					p[0] = y0;
					p[1] = u;
					p[2] = y1;
					p[3] = v;
				}
			}
			break;
		}
	}

	void run(Camera_Sink &sink) {
		auto next = std::chrono::steady_clock::now();
		for (int frame = 0; !quit_.load(); frame++) {
			draw(frame);
			if (!buf_.empty()) {
				Camera_Frame f{format_, FAKE_WIDTH, FAKE_HEIGHT, buf_.data(), buf_.size(),
				               format_ == Camera_Format::BGRX};
				sink.frame(f);
			}
			next += std::chrono::microseconds(1'000'000 / FAKE_FPS);
			std::this_thread::sleep_until(next);
		}
	}
};

} // namespace

bool fake_camera(Camera_Info &info) {
	Camera_Format f = fake_format();
	if (f == Camera_Format::OTHER) {
		return false;
	}
	info = {};
	copy_name(info.camera.id, sizeof(info.camera.id), FAKE_CAMERA_ID);
	copy_name(info.camera.name, sizeof(info.camera.name), "Fake camera");
	info.camera.max_width = FAKE_WIDTH;
	info.camera.max_height = FAKE_HEIGHT;
	info.camera.max_fps = FAKE_FPS;
	Camera_Mode m;
	m.min_width = m.max_width = FAKE_WIDTH;
	m.min_height = m.max_height = FAKE_HEIGHT;
	m.min_fps = m.max_fps = FAKE_FPS;
	m.format = f;
	info.modes.push_back(m);
	return true;
}

std::unique_ptr<Camera_Source> make_fake_source() {
	return std::make_unique<Fake_Source>();
}

} // namespace yv
