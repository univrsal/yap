/*
Sharing's platform part: capturing a source and turning what it captured
into frames an encoder takes. share.cpp does the rest (the thread, when
to encode, the encoder, the packets) the same everywhere. Windows has
capture_win.cpp, Linux capture_linux.h; macOS doesn't capture yet.
*/
#pragma once

#include "internal.h"

#include <atomic>
#include <memory>
#include <string>

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
};

std::unique_ptr<Pipeline> make_pipeline();

// Whether `codec` takes `fmt` as input (encoders.cpp).
bool takes_pix_fmt(const AVCodec *codec, int fmt);

// nv12_to_i420 makes `dst` a YUV420P copy of the NV12 frame `src` in
// memory, for encoders that take nothing else (OpenH264).
bool nv12_to_i420(const AVFrame *src, AVFrame *dst);

} // namespace yv
