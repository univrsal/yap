/*
Cameras on Linux, through V4L2 directly: every /dev/video* that captures
video, with the formats, sizes and frame rates it says it has, captured
into memory-mapped buffers on a thread of the source's own.

Cameras that only send grey (laptops' infrared ones, for face login)
aren't listed, and neither are the metadata nodes UVC cameras have next
to their video ones. A camera's id is its /dev/v4l/by-id name where it
has one, which stays the same when it's plugged in elsewhere, and its
/dev/videoN otherwise (virtual cameras, such as OBS's v4l2loopback).

Laptop cameras behind libcamera (Intel IPU6) aren't V4L2 capture
devices; they need PipeWire, which is for later (D5 in
misc/video-chat/README.md). YAP_VIDEO_FAKE_CAMERA's camera is listed
first (camera_fake.cpp).
*/
#include "pipeline.h"

#include <linux/videodev2.h>

#include <dirent.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <climits>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <map>
#include <thread>

namespace yv {

namespace {

int xioctl(int fd, unsigned long request, void *arg) {
	int r;
	do {
		r = ioctl(fd, request, arg);
	} while (r == -1 && errno == EINTR);
	return r;
}

Camera_Format format_of(uint32_t pix) {
	switch (pix) {
	case V4L2_PIX_FMT_YUYV:
		return Camera_Format::YUY2;
	case V4L2_PIX_FMT_UYVY:
		return Camera_Format::UYVY;
	case V4L2_PIX_FMT_YVYU:
		return Camera_Format::YVYU;
	case V4L2_PIX_FMT_NV12:
		return Camera_Format::NV12;
	case V4L2_PIX_FMT_YUV420:
		return Camera_Format::I420;
	case V4L2_PIX_FMT_YVU420:
		return Camera_Format::YV12;
	case V4L2_PIX_FMT_MJPEG:
	case V4L2_PIX_FMT_JPEG:
		return Camera_Format::MJPEG;
	case V4L2_PIX_FMT_BGR24: // B, G, R in memory
		return Camera_Format::BGR24;
	case V4L2_PIX_FMT_XBGR32: // B, G, R, X in memory
	case V4L2_PIX_FMT_BGR32:
		return Camera_Format::BGRX;
	case V4L2_PIX_FMT_ABGR32:
		return Camera_Format::BGRA;
	case V4L2_PIX_FMT_GREY:
		return Camera_Format::GRAY;
	default:
		return Camera_Format::OTHER;
	}
}

double fps_of(const v4l2_fract &interval) {
	return interval.numerator > 0 ? static_cast<double>(interval.denominator) / interval.numerator
	                              : 0;
}

// The frame rates the camera has for a format at a size; none if it doesn't
// say, which camera.cpp takes for fast enough.
void rates(int fd, uint32_t pix, uint32_t w, uint32_t h, Camera_Mode &m) {
	v4l2_frmivalenum iv{};
	iv.pixel_format = pix;
	iv.width = w;
	iv.height = h;
	for (iv.index = 0; xioctl(fd, VIDIOC_ENUM_FRAMEINTERVALS, &iv) == 0; iv.index++) {
		if (iv.type != V4L2_FRMIVAL_TYPE_DISCRETE) {
			m.max_fps = fps_of(iv.stepwise.min);
			m.min_fps = fps_of(iv.stepwise.max);
			return;
		}
		double fps = fps_of(iv.discrete);
		m.max_fps = std::max(m.max_fps, fps);
		m.min_fps = iv.index == 0 ? fps : std::min(m.min_fps, fps);
	}
}

void add_modes(int fd, uint32_t pix, Camera_Format format, std::vector<Camera_Mode> &out) {
	v4l2_frmsizeenum s{};
	s.pixel_format = pix;
	for (s.index = 0; xioctl(fd, VIDIOC_ENUM_FRAMESIZES, &s) == 0; s.index++) {
		Camera_Mode m;
		m.format = format;
		m.native = pix;
		if (s.type == V4L2_FRMSIZE_TYPE_DISCRETE) {
			m.min_width = m.max_width = static_cast<int>(s.discrete.width);
			m.min_height = m.max_height = static_cast<int>(s.discrete.height);
			rates(fd, pix, s.discrete.width, s.discrete.height, m);
			out.push_back(m);
			continue;
		}
		// Stepwise or continuous: one range, with the rates at its largest.
		m.min_width = static_cast<int>(s.stepwise.min_width);
		m.max_width = static_cast<int>(s.stepwise.max_width);
		m.min_height = static_cast<int>(s.stepwise.min_height);
		m.max_height = static_cast<int>(s.stepwise.max_height);
		m.step_width = std::max(1, static_cast<int>(s.stepwise.step_width));
		m.step_height = std::max(1, static_cast<int>(s.stepwise.step_height));
		rates(fd, pix, s.stepwise.max_width, s.stepwise.max_height, m);
		out.push_back(m);
		break;
	}
}

// /dev/videoN -> /dev/v4l/by-id/<name>, for the cameras that have one.
std::map<std::string, std::string> stable_names() {
	std::map<std::string, std::string> names;
	const char *dir = "/dev/v4l/by-id";
	DIR *d = opendir(dir);
	if (!d) {
		return names;
	}
	while (dirent *e = readdir(d)) {
		if (e->d_name[0] == '.') {
			continue;
		}
		std::string link = std::string(dir) + "/" + e->d_name;
		char real[PATH_MAX];
		if (realpath(link.c_str(), real)) {
			// The first; a camera's nodes all have one ("-video-index0", "-index1").
			auto it = names.find(real);
			if (it == names.end() || link < it->second) {
				names[real] = link;
			}
		}
	}
	closedir(d);
	return names;
}

// The /dev/video* there are, in the order of their numbers.
std::vector<int> video_nodes() {
	std::vector<int> nodes;
	DIR *d = opendir("/dev");
	if (!d) {
		return nodes;
	}
	while (dirent *e = readdir(d)) {
		const char *n = e->d_name;
		if (strncmp(n, "video", 5) == 0 && n[5] >= '0' && n[5] <= '9') {
			nodes.push_back(atoi(n + 5));
		}
	}
	closedir(d);
	std::sort(nodes.begin(), nodes.end());
	return nodes;
}

class Source_V4l2 final : public Camera_Source {
public:
	~Source_V4l2() override {
		quit_.store(true);
		if (thread_.joinable()) {
			thread_.join();
		}
		if (fd_ >= 0) {
			v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
			xioctl(fd_, VIDIOC_STREAMOFF, &type);
		}
		for (Buffer &b : buffers_) {
			munmap(b.data, b.length);
		}
		if (fd_ >= 0) {
			close(fd_);
		}
	}

	bool open(const Camera_Info &camera, const Camera_Mode &mode, int w, int h, double fps,
	          Camera_Sink &sink, std::string &error) override {
		fd_ = ::open(camera.path.c_str(), O_RDWR | O_NONBLOCK | O_CLOEXEC);
		if (fd_ < 0) {
			error = errno == EACCES ? "yap may not open the camera (" + camera.path + ")"
			                        : "the camera won't open";
			return false;
		}
		v4l2_format f{};
		f.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
		f.fmt.pix.width = static_cast<uint32_t>(w);
		f.fmt.pix.height = static_cast<uint32_t>(h);
		f.fmt.pix.pixelformat = mode.native;
		f.fmt.pix.field = V4L2_FIELD_ANY;
		if (xioctl(fd_, VIDIOC_S_FMT, &f) < 0) {
			error = errno == EBUSY ? "another program is using the camera"
			                       : "the camera won't take that format";
			return false;
		}
		// What it took, which may not be quite what was asked.
		width_ = static_cast<int>(f.fmt.pix.width);
		height_ = static_cast<int>(f.fmt.pix.height);
		format_ = format_of(f.fmt.pix.pixelformat);
		stride_ = format_ == Camera_Format::MJPEG ? 0 : static_cast<int>(f.fmt.pix.bytesperline);
		if (format_ == Camera_Format::OTHER || width_ <= 0 || height_ <= 0) {
			error = "the camera won't take that format";
			return false;
		}
		v4l2_streamparm parm{};
		parm.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
		if (fps > 0 && xioctl(fd_, VIDIOC_G_PARM, &parm) == 0 &&
		    (parm.parm.capture.capability & V4L2_CAP_TIMEPERFRAME)) {
			parm.parm.capture.timeperframe.numerator = 1000;
			parm.parm.capture.timeperframe.denominator = static_cast<uint32_t>(std::lround(fps * 1000));
			xioctl(fd_, VIDIOC_S_PARM, &parm);
		}
		if (!map_buffers(error)) {
			return false;
		}
		v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
		if (xioctl(fd_, VIDIOC_STREAMON, &type) < 0) {
			error = errno == EBUSY ? "another program is using the camera"
			                       : "the camera won't start";
			return false;
		}
		if (width_ != w || height_ != h) {
			log(YV_LOG_INFO, "camera: it gives %dx%d", width_, height_);
		}
		thread_ = std::thread([this, &sink] { run(sink); });
		return true;
	}

private:
	struct Buffer {
		void *data;
		size_t length;
	};

	int fd_ = -1;
	std::vector<Buffer> buffers_;
	Camera_Format format_ = Camera_Format::OTHER;
	int width_ = 0, height_ = 0, stride_ = 0;
	std::atomic<bool> quit_{false};
	std::thread thread_;

	bool map_buffers(std::string &error) {
		v4l2_requestbuffers req{};
		req.count = 4;
		req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
		req.memory = V4L2_MEMORY_MMAP;
		if (xioctl(fd_, VIDIOC_REQBUFS, &req) < 0 || req.count == 0) {
			error = errno == EBUSY ? "another program is using the camera"
			                       : "the camera has no buffers to give";
			return false;
		}
		for (uint32_t i = 0; i < req.count; i++) {
			v4l2_buffer b{};
			b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
			b.memory = V4L2_MEMORY_MMAP;
			b.index = i;
			if (xioctl(fd_, VIDIOC_QUERYBUF, &b) < 0) {
				error = "the camera's buffers can't be had";
				return false;
			}
			void *p = mmap(nullptr, b.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd_, b.m.offset);
			if (p == MAP_FAILED) {
				error = "the camera's buffers can't be mapped";
				return false;
			}
			buffers_.push_back({p, b.length});
			if (xioctl(fd_, VIDIOC_QBUF, &b) < 0) {
				error = "the camera won't take its buffers";
				return false;
			}
		}
		return true;
	}

	// Hands each frame on until quit_; one that comes with an error is
	// dropped. A camera that's unplugged ends it, and camera.cpp then finds
	// it stalled.
	void run(Camera_Sink &sink) {
		while (!quit_.load()) {
			pollfd p{fd_, POLLIN, 0};
			int r = poll(&p, 1, 100);
			if (r <= 0) {
				continue;
			}
			v4l2_buffer b{};
			b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
			b.memory = V4L2_MEMORY_MMAP;
			if (xioctl(fd_, VIDIOC_DQBUF, &b) < 0) {
				if (errno == ENODEV) {
					log(YV_LOG_WARN, "camera: it's gone");
					return;
				}
				if (errno != EAGAIN) {
					// Not streaming for the moment (a virtual camera with nothing
					// behind it): don't spin.
					std::this_thread::sleep_for(std::chrono::milliseconds(50));
				}
				continue;
			}
			if (!(b.flags & V4L2_BUF_FLAG_ERROR) && b.bytesused > 0 && b.index < buffers_.size()) {
				Camera_Frame f{format_, width_, height_,
				               static_cast<const uint8_t *>(buffers_[b.index].data), b.bytesused,
				               false, stride_};
				sink.frame(f);
			}
			xioctl(fd_, VIDIOC_QBUF, &b);
		}
	}
};

} // namespace

std::vector<Camera_Info> list_cameras() {
	std::vector<Camera_Info> out;
	Camera_Info fake;
	if (fake_camera(fake)) {
		out.push_back(fake);
	}
	std::map<std::string, std::string> stable = stable_names();
	for (int n : video_nodes()) {
		std::string path = "/dev/video" + std::to_string(n);
		int fd = ::open(path.c_str(), O_RDWR | O_NONBLOCK | O_CLOEXEC);
		if (fd < 0) {
			log(YV_LOG_DEBUG, "camera: can't open %s: %s", path.c_str(), strerror(errno));
			continue;
		}
		v4l2_capability cap{};
		if (xioctl(fd, VIDIOC_QUERYCAP, &cap) < 0) {
			close(fd);
			continue;
		}
		uint32_t caps = (cap.capabilities & V4L2_CAP_DEVICE_CAPS) ? cap.device_caps : cap.capabilities;
		if (!(caps & V4L2_CAP_VIDEO_CAPTURE) || !(caps & V4L2_CAP_STREAMING)) {
			close(fd);
			continue;
		}
		Camera_Info info;
		v4l2_fmtdesc d{};
		d.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
		for (d.index = 0; xioctl(fd, VIDIOC_ENUM_FMT, &d) == 0; d.index++) {
			Camera_Format f = format_of(d.pixelformat);
			// Formats libv4l makes up from others aren't the camera's own.
			if (f != Camera_Format::OTHER && !(d.flags & V4L2_FMT_FLAG_EMULATED)) {
				add_modes(fd, d.pixelformat, f, info.modes);
			}
		}
		close(fd);
		bool colour = std::any_of(info.modes.begin(), info.modes.end(),
		                          [](const Camera_Mode &m) { return m.format != Camera_Format::GRAY; });
		if (!colour) {
			continue;
		}
		info.name = reinterpret_cast<const char *>(cap.card);
		info.path = path;
		auto it = stable.find(path);
		copy_name(info.camera.id, sizeof(info.camera.id), it != stable.end() ? it->second : path);
		copy_name(info.camera.name, sizeof(info.camera.name), info.name);
		for (const Camera_Mode &m : info.modes) {
			int64_t area = static_cast<int64_t>(m.max_width) * m.max_height;
			int64_t best = static_cast<int64_t>(info.camera.max_width) * info.camera.max_height;
			int fps = static_cast<int>(std::lround(m.max_fps));
			if (area > best || (area == best && fps > info.camera.max_fps)) {
				info.camera.max_width = m.max_width;
				info.camera.max_height = m.max_height;
				info.camera.max_fps = fps;
			}
		}
		out.push_back(std::move(info));
	}
	return out;
}

bool camera_allowed(bool, const std::atomic<bool> *) {
	return true;
}

std::unique_ptr<Camera_Source> make_camera_source(const Camera_Info &camera) {
	if (strcmp(camera.camera.id, FAKE_CAMERA_ID) == 0) {
		return make_fake_source();
	}
	return std::make_unique<Source_V4l2>();
}

} // namespace yv
