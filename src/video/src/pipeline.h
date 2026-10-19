/*
Sharing's platform part: capturing a source and turning what it captured
into frames an encoder takes. share.cpp does the rest (the thread, when
to encode, the encoder, the packets) the same everywhere. Windows has
capture_win.cpp, Linux capture_linux.h, macOS capture_mac.mm; cameras
are below.
*/
#pragma once

#include "internal.h"

#include <atomic>
#include <memory>
#include <string>
#include <vector>

#include "ffmpeg.h"

namespace yv {

class Pipeline {
public:
	virtual ~Pipeline() = default;

	/*
	open starts capturing; false with `error` set if it can't.
	`encoder` is the FFmpeg encoder that will be used, so the GPU can
	be chosen to suit it. Where the system asks the user what to share
	(the portal), open waits for the answer, or for `stop`.
	*/
	virtual bool open(const yv_share_config &config, const char *encoder,
	                  const std::atomic<bool> &stop, std::string &error) = 0;

	// After open failed: because the user said no in the system's
	// picker, which isn't an error worth showing.
	virtual bool cancelled() {
		return false;
	}

	/*
	wait waits up to `ms` for something new to have been captured, and
	says whether it was. The newest capture is kept, so convert can make
	a frame of it again later (for a keyframe on a still screen). False
	with `closed` set when the source went away (a window closed).
	*/
	virtual bool wait(int ms, bool &closed) = 0;

	// The size of the newest capture, 0 before there's one.
	virtual int width() = 0;
	virtual int height() = 0;

	// The device encoders work on (a new reference), or nullptr.
	virtual AVBufferRef *hw_device() = 0;
	// A pool of w x h frames on that device that convert can render or
	// upload into (a new reference), or nullptr if there's none, in
	// which case convert makes frames in memory. The encoder only gets
	// them if it takes their format.
	virtual AVBufferRef *hw_frames(int w, int h) = 0;

	/*
	convert scales the newest capture to w x h and converts it to NV12,
	BT.709 limited, into `out`: a frame from `frames` if that isn't
	nullptr, else one in memory (allocated here).
	*/
	virtual bool convert(AVFrame *out, AVBufferRef *frames, int w, int h) = 0;

	// What to say when wait found the source gone.
	virtual std::string gone() {
		return "what was shared went away";
	}
};

std::unique_ptr<Pipeline> make_pipeline();

/*
Cameras. camera.cpp is the Pipeline, the same everywhere: it picks the
camera's mode, decodes MJPEG, and scales and converts on the CPU. The
platform part (camera_win.cpp, camera_v4l2.cpp, camera_mac.mm)
lists the cameras and hands over what one captures.
*/
enum class Camera_Format {
	NV12,
	I420,
	YV12,
	YUY2,
	UYVY,
	YVYU,
	BGRA,
	BGRX,
	BGR24,
	GRAY,
	MJPEG,
	OTHER, // nothing that can be taken
};

// A way a camera can capture: one size (min == max), or sizes in steps.
struct Camera_Mode {
	int min_width = 0, min_height = 0, max_width = 0, max_height = 0;
	int step_width = 1, step_height = 1;
	double min_fps = 0, max_fps = 0;
	Camera_Format format = Camera_Format::OTHER;
	uint32_t native = 0; // what the platform calls the format, where it needs it (V4L2)
};

struct Camera_Info {
	yv_camera camera{};
	std::vector<Camera_Mode> modes;
	// What the platform opens it by.
	std::string name, path;
};

struct Camera_Frame {
	Camera_Format format;
	int width, height;
	const uint8_t *data; // valid during Camera_Sink::frame only
	size_t size;
	bool flip; // the rows are bottom-up
	// Bytes from one row of the first plane to the next; 0 where the rows
	// are as long as the picture is wide (or the size says, for one plane).
	// Planar formats' chroma rows are half as long.
	int stride = 0;
	// The YUV is BT.709 rather than BT.601 (macOS says which).
	bool bt709 = false;
};

class Camera_Sink {
public:
	virtual ~Camera_Sink() = default;
	// From the source's own thread, one frame at a time.
	virtual void frame(const Camera_Frame &f) = 0;
};

class Camera_Source {
public:
	// Stops the camera: no more frames once it returns.
	virtual ~Camera_Source() = default;
	/*
	open starts capturing `mode` at w x h and fps, handing each frame to
	`sink`; false with `error` set if it can't. From the share's thread,
	which the source is destroyed on too.
	*/
	virtual bool open(const Camera_Info &camera, const Camera_Mode &mode, int w, int h, double fps,
	                  Camera_Sink &sink, std::string &error) = 0;
};

std::vector<Camera_Info> list_cameras();
/*
Whether the system lets us use a camera. `ask` asks the user where the
system does (macOS) and they haven't answered yet, and waits for the
answer, or for `stop`.
*/
bool camera_allowed(bool ask, const std::atomic<bool> *stop = nullptr);
// What captures `camera`; nullptr where cameras can't be captured.
std::unique_ptr<Camera_Source> make_camera_source(const Camera_Info &camera);

// camera_fake.cpp (Linux, macOS): YAP_VIDEO_FAKE_CAMERA's camera, if it's set.
constexpr const char *FAKE_CAMERA_ID = "fake";
bool fake_camera(Camera_Info &out);
std::unique_ptr<Camera_Source> make_fake_source();
// The camera with yv_camera.id `id` ("" for the first) as a Pipeline.
std::unique_ptr<Pipeline> make_camera_pipeline(const std::string &id);

// Whether `codec` takes `fmt` as input (encoders.cpp).
bool takes_pix_fmt(const AVCodec *codec, int fmt);

// nv12_to_i420 makes `dst` a YUV420P copy of the NV12 frame `src` in
// memory, for encoders that take nothing else (OpenH264).
bool nv12_to_i420(const AVFrame *src, AVFrame *dst);

} // namespace yv
