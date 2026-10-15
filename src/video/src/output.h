/*
Where a view's decoded frames go: the part of watching that depends on
the client's graphics API. The view's decoder thread hands each frame
over (submit), and the client's drawing thread takes the newest one
(present). On Windows that's D3D11 (output_d3d11.cpp), on macOS Metal
(output_metal.mm), elsewhere OpenGL (output_gl.cpp).
*/
#pragma once

#include "internal.h"

#include <memory>

extern "C" {
#include <libavutil/buffer.h>
#include <libavutil/frame.h>
struct SwsContext;
}

namespace yv {

class Output {
public:
	virtual ~Output() = default;

	// The decoder thread's side.

	// The device hardware decoders decode on (a new reference), or
	// nullptr for decoding in software only.
	virtual AVBufferRef *hw_device() = 0;
	// Whether the hardware decodes this codec at all; asked before
	// trying, for decoders that have no software fallback of their own
	// (FFmpeg's native AV1).
	virtual bool hw_decodes(yv_codec codec) = 0;
	// Whether the device decoders are on has to be made again (the
	// client moved to another GPU); the decoder goes with it.
	virtual bool device_stale() = 0;
	virtual void renew_device() = 0;
	// submit makes `frame` (decoded in hardware or software) the newest
	// picture. False if it couldn't, which fails the decoder.
	virtual bool submit(const AVFrame *frame) = 0;

	// Any thread: no picture until the next submit.
	virtual void clear() = 0;

	/*
	The client's drawing thread, but for set_gpu from yv_view_create,
	before there's anything on the client's device to let go of. `luid`
	is gpu_luid's, which set_gpu mustn't ask the device for itself.
	*/
	virtual void set_gpu(const yv_gpu *gpu, uint64_t luid) = 0;
	virtual bool present(yv_picture *out) = 0;
};

std::unique_ptr<Output> make_output();



/*
The YUV to RGB conversion both outputs' shaders do, as three rows:
rgb = (dot(row0, yuv1), dot(row1, yuv1), dot(row2, yuv1)) with
yuv1 = (y, u, v, 1), from the frame's colour matrix and range.
*/
struct Yuv_Matrix {
	float rows[3][4];
};
Yuv_Matrix yuv_matrix(const AVFrame *frame);

/*
Software frames reach the shaders as NV12: a full size Y plane and a
half size plane of U and V interleaved. Nv12 converts what decoders
hand out (I420 mostly, NV12 from hardware) to that.
*/
class Nv12 {
public:
	Nv12();
	~Nv12();
	Nv12(const Nv12 &) = delete;
	Nv12 &operator=(const Nv12 &) = delete;
	// `src` itself if it's NV12 already, else a converted copy that's
	// valid until the next call; nullptr if it can't be converted.
	const AVFrame *convert(const AVFrame *src);

private:
	AVFrame *out_;
	SwsContext *sws_ = nullptr;
};

} // namespace yv
