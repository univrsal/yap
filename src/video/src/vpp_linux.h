/*
VA-API's video processor, for turning a captured RGB surface into the
encoder's NV12 on the GPU (portal_linux.cpp's DMA-BUFs): scaled to fit,
BT.709 limited range. FFmpeg does this in libavfilter (scale_vaapi),
which yap_video doesn't use, so it's libva's own calls, loaded at run
time (dl_linux.h) like the rest of the system's libraries.
*/
#pragma once

#include <cstdint>

extern "C" {
#include <libavutil/buffer.h>
}

namespace yv {

class Vpp {
public:
	Vpp() = default;
	~Vpp();
	Vpp(const Vpp &) = delete;
	Vpp &operator=(const Vpp &) = delete;

	// Whether libva is there to do it.
	static bool available();

	/*
	run draws the part of surface `in` at x, y, w, h into surface `out`
	(an NV12 surface of out_w x out_h) and waits until it's done. Both
	are surfaces of `device`, an FFmpeg VA-API device.
	*/
	bool run(AVBufferRef *device, uint32_t in, int x, int y, int w, int h, uint32_t out,
	         int out_w, int out_h);

private:
	void *dpy_ = nullptr;
	uint32_t config_ = 0xffffffff, context_ = 0xffffffff;
	int context_w_ = 0, context_h_ = 0;

	void destroy();
};

} // namespace yv
