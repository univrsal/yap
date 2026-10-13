/*
Capturing on Linux, the part both ways of capturing share. X11 desktops
are captured with XCB (x11_linux.cpp): our own list of monitors and
windows, and pictures taken at the share's rate. Wayland desktops only
let the portal capture (portal_linux.cpp): it shows its own picker, and
PipeWire brings what it captures. Either way the picture arrives in
memory, as BGRA or something like it.

Memory_Pipeline turns that into the encoder's NV12 with swscale (BT.709,
limited range, scaled to fit), and uploads it to a VA-API surface for
the VA-API encoders, which take nothing else. NVENC takes it from
memory as it is. Keeping it on the GPU is phase 9's.
*/
#pragma once

#include "pipeline.h"

#include <atomic>
#include <cstdint>
#include <vector>

extern "C" {
#include <libavutil/pixfmt.h>
struct SwsContext;
}

namespace yv {

// A captured picture in memory.
struct Image {
	std::vector<uint8_t> data;
	int width = 0, height = 0, stride = 0;
	AVPixelFormat format = AV_PIX_FMT_NONE; // BGR0, BGRA, RGB0 or RGBA
};

class Memory_Pipeline : public Pipeline {
public:
	~Memory_Pipeline() override;

	int width() override {
		return latest_.width;
	}
	int height() override {
		return latest_.height;
	}
	AVBufferRef *hw_device() override;
	AVBufferRef *hw_frames(int w, int h) override;
	bool convert(AVFrame *out, AVBufferRef *frames, int w, int h) override;

protected:
	// open_device makes a VA-API device if `encoder` is a VA-API one.
	void open_device(const char *encoder);
	// That device (not a new reference), or nullptr.
	AVBufferRef *device() {
		return device_;
	}

	// The newest capture, which convert works from; the share's thread's.
	Image latest_;

private:
	AVBufferRef *device_ = nullptr;
	SwsContext *sws_ = nullptr;
	AVFrame *nv12_ = nullptr; // for uploading
};

enum class Capture_Kind { None, X11, Portal };

// How this desktop is captured; YAP_VIDEO_CAPTURE=x11 or portal says.
Capture_Kind capture_kind();

std::vector<yv_source> x11_sources();
std::unique_ptr<Pipeline> x11_pipeline();
// Whether the X server can be reached and XCB loaded.
bool x11_usable();

std::unique_ptr<Pipeline> portal_pipeline();
// Whether the portal offers screen casting and PipeWire loaded.
bool portal_usable();

} // namespace yv
