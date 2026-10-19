/*
Watching with Metal (macOS). The newest frame waits until present
converts its two NV12 planes into an RGBA texture with a small shader,
on the client's own command queue, so the client's frames that draw the
picture come after it, and the conversion after the frames that drew the
one before: Metal keeps the order of what one queue does with a texture.

A frame decoded by VideoToolbox is a CVPixelBuffer backed by an
IOSurface, whose planes are made into textures where they lie (Y as R8,
UV as RG8), and the frame is held until the GPU is done with them. A
frame decoded in software, or one VideoToolbox gives in a format this
doesn't take (10 bit), is copied into textures of our own; after the
first of those, hardware frames are copied back to memory as they're
decoded and go that way too.
*/
#include "output.h"

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <vector>

#include <CoreVideo/CoreVideo.h>
#include <IOSurface/IOSurfaceObjC.h>
#include <Metal/Metal.h>

#include "ffmpeg.h"

namespace yv {

namespace {

const char SHADERS[] = R"(
#include <metal_stdlib>
using namespace metal;

struct Rows {
	float4 row0;
	float4 row1;
	float4 row2;
};

struct Varying {
	float4 pos [[position]];
	float2 uv;
};

// One triangle that covers the whole target, from the vertex ids alone.
// The picture's top row goes to the texture's first row.
vertex Varying vs(uint id [[vertex_id]]) {
	float2 p = float2((id << 1) & 2, id & 2);
	Varying v;
	v.pos = float4(p.x * 2 - 1, 1 - p.y * 2, 0, 1);
	v.uv = p;
	return v;
}

fragment float4 ps(Varying v [[stage_in]], constant Rows &rows [[buffer(0)]],
                   texture2d<float> plane_y [[texture(0)]], texture2d<float> plane_uv [[texture(1)]]) {
	constexpr sampler linear_clamp(filter::linear, address::clamp_to_edge);
	float4 yuv = float4(plane_y.sample(linear_clamp, v.uv).r, plane_uv.sample(linear_clamp, v.uv).rg, 1);
	return float4(dot(rows.row0, yuv), dot(rows.row1, yuv), dot(rows.row2, yuv), 1);
}
)";

// Whether frames decoded in hardware go to Metal as they are.
enum Interop_State { INTEROP_UNKNOWN, INTEROP_WORKS, INTEROP_NONE };

// plane_texture makes plane `p` of an IOSurface into a texture of `format`,
// or nil.
id<MTLTexture> plane_texture(id<MTLDevice> device, IOSurfaceRef surface, size_t p,
                             MTLPixelFormat format) {
	MTLTextureDescriptor *desc = [MTLTextureDescriptor
		texture2DDescriptorWithPixelFormat:format
		                             width:IOSurfaceGetWidthOfPlane(surface, p)
		                            height:IOSurfaceGetHeightOfPlane(surface, p)
		                         mipmapped:NO];
	desc.usage = MTLTextureUsageShaderRead;
	return [device newTextureWithDescriptor:desc iosurface:surface plane:p];
}

class Output_Metal final : public Output {
public:
	~Output_Metal() override {
		av_buffer_unref(&hw_device_);
		av_frame_free(&sw_);
		av_frame_free(&latest_hw_);
	}

	AVBufferRef *hw_device() override {
		if (software_only()) {
			return nullptr;
		}
		if (!tried_device_) {
			tried_device_ = true;
			Quiet_FFmpeg quiet;
			if (av_hwdevice_ctx_create(&hw_device_, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nullptr, nullptr,
			                           0) < 0) {
				log(YV_LOG_INFO, "video: no hardware decoding (videotoolbox)");
			}
		}
		return hw_device_ ? av_buffer_ref(hw_device_) : nullptr;
	}

	// AV1 in hardware isn't tried yet (FFmpeg's AV1 decoder has no
	// software fallback to find out with); dav1d does it.
	bool hw_decodes(yv_codec codec) override {
		return codec != YV_CODEC_AV1 && hw_device_ != nullptr;
	}

	bool device_stale() override {
		return false;
	}

	void renew_device() override {}

	bool submit(const AVFrame *frame) override {
		const AVFrame *f = frame;
		bool hardware = frame->hw_frames_ctx != nullptr;
		if (hardware && interop_state_.load() != INTEROP_NONE) {
			// Kept on the GPU for present.
			if (AVFrame *keep = av_frame_clone(frame)) {
				std::lock_guard<std::mutex> lock(mutex_);
				av_frame_free(&latest_hw_);
				latest_hw_ = keep;
				noted(frame, frame->width, frame->height, true);
				return true;
			}
		}
		if (hardware) {
			if (!sw_) {
				sw_ = av_frame_alloc();
			}
			av_frame_unref(sw_);
			if (av_hwframe_transfer_data(sw_, frame, 0) < 0 || av_frame_copy_props(sw_, frame) < 0) {
				return false;
			}
			f = sw_;
		}
		f = nv12_.convert(f);
		if (!f) {
			return false;
		}
		std::lock_guard<std::mutex> lock(mutex_);
		av_frame_free(&latest_hw_);
		copy_planes(f);
		noted(frame, f->width, f->height, hardware);
		return true;
	}

	void clear() override {
		std::lock_guard<std::mutex> lock(mutex_);
		av_frame_free(&latest_hw_);
		fresh_ = false;
		frames_ = 0;
		cleared_ = true;
	}

	void set_gpu(const yv_gpu *gpu, uint64_t) override {
		bool metal = gpu && gpu->kind == YV_GPU_METAL;
		id<MTLDevice> device = metal ? (__bridge id<MTLDevice>)gpu->metal_device : nil;
		id<MTLCommandQueue> queue = metal ? (__bridge id<MTLCommandQueue>)gpu->metal_queue : nil;
		if (device == device_ && queue == queue_) {
			return;
		}
		drop();
		device_ = device;
		queue_ = queue;
		// A new device may take the GPU's frames where the old didn't.
		interop_state_.store(INTEROP_UNKNOWN);
		have_picture_ = false;
		std::lock_guard<std::mutex> lock(mutex_);
		fresh_ = latest_w_ > 0; // convert the newest again, on the new device
	}

	bool present(yv_picture *out) override {
		if (!device_) {
			return false;
		}
		{
			std::lock_guard<std::mutex> lock(mutex_);
			if (cleared_) {
				cleared_ = false;
				have_picture_ = false;
			}
			out->frames = frames_;
			if (fresh_) {
				fresh_ = false;
				@autoreleasepool {
					if (draw()) {
						have_picture_ = true;
						hardware_ = latest_hardware_;
						pts_ = latest_pts_;
					}
				}
			}
		}
		if (!have_picture_) {
			return false;
		}
		out->texture = reinterpret_cast<uintptr_t>((__bridge void *)rgba_);
		out->width = static_cast<int32_t>(rgba_.width);
		out->height = static_cast<int32_t>(rgba_.height);
		out->hardware = hardware_;
		out->pts_us = pts_;
		return true;
	}

private:
	// The decoder thread's.
	AVBufferRef *hw_device_ = nullptr;
	bool tried_device_ = false;
	AVFrame *sw_ = nullptr;
	Nv12 nv12_;

	// The newest frame, under mutex_: on the GPU (latest_hw_), or its
	// planes in memory.
	std::mutex mutex_;
	AVFrame *latest_hw_ = nullptr;
	std::vector<uint8_t> latest_y_, latest_uv_;
	int latest_w_ = 0, latest_h_ = 0;
	Yuv_Matrix latest_matrix_{};
	bool latest_hardware_ = false;
	uint64_t latest_pts_ = 0;
	bool fresh_ = false;
	bool cleared_ = false;
	uint64_t frames_ = 0;
	std::atomic<int> interop_state_{INTEROP_UNKNOWN};

	// The drawing thread's: the client's device and queue, and what's
	// made on them.
	id<MTLDevice> device_ = nil;
	id<MTLCommandQueue> queue_ = nil;
	id<MTLRenderPipelineState> pipeline_ = nil;
	id<MTLTexture> plane_y_ = nil, plane_uv_ = nil, rgba_ = nil;
	// The last conversion from plane_y_ and plane_uv_, which have to wait
	// for it before they're written again.
	id<MTLCommandBuffer> planes_read_ = nil;
	Nv12 draw_nv12_; // for the one frame copied back here
	bool have_picture_ = false;
	bool hardware_ = false;
	uint64_t pts_ = 0;

	// noted records the newest frame's particulars. With mutex_ held.
	void noted(const AVFrame *frame, int w, int h, bool hardware) {
		latest_w_ = w;
		latest_h_ = h;
		latest_matrix_ = yuv_matrix(frame);
		latest_hardware_ = hardware;
		latest_pts_ = static_cast<uint64_t>(frame->pts);
		fresh_ = true;
		frames_++;
	}

	// copy_planes keeps an NV12 frame's planes for uploading. With
	// mutex_ held.
	void copy_planes(const AVFrame *f) {
		int cw = (f->width + 1) / 2, ch = (f->height + 1) / 2;
		latest_y_.resize(static_cast<size_t>(f->width) * f->height);
		latest_uv_.resize(static_cast<size_t>(cw) * 2 * ch);
		for (int y = 0; y < f->height; y++) {
			memcpy(&latest_y_[static_cast<size_t>(y) * f->width], f->data[0] + y * f->linesize[0],
			       f->width);
		}
		for (int y = 0; y < ch; y++) {
			memcpy(&latest_uv_[static_cast<size_t>(y) * cw * 2], f->data[1] + y * f->linesize[1],
			       cw * 2);
		}
	}

	void drop() {
		[planes_read_ waitUntilCompleted];
		planes_read_ = nil;
		pipeline_ = nil;
		plane_y_ = plane_uv_ = rgba_ = nil;
		device_ = nil;
		queue_ = nil;
	}

	bool make_pipeline() {
		NSError *err = nil;
		id<MTLLibrary> library = [device_ newLibraryWithSource:@(SHADERS) options:nil error:&err];
		if (!library) {
			log(YV_LOG_ERROR, "video: shader: %s", err.localizedDescription.UTF8String);
			return false;
		}
		MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
		desc.vertexFunction = [library newFunctionWithName:@"vs"];
		desc.fragmentFunction = [library newFunctionWithName:@"ps"];
		desc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
		pipeline_ = [device_ newRenderPipelineStateWithDescriptor:desc error:&err];
		if (!pipeline_) {
			log(YV_LOG_ERROR, "video: no pipeline: %s", err.localizedDescription.UTF8String);
			return false;
		}
		return true;
	}

	/*
	hw_planes makes the GPU frame's planes into textures where they lie,
	if it can. If it can't, it's the last time it's tried: the frame is
	copied back here (and the decoder copies the rest back itself), and
	false. With mutex_ held.
	*/
	bool hw_planes(id<MTLTexture> __strong &y, id<MTLTexture> __strong &uv) {
		if (interop_state_.load() != INTEROP_NONE && !getenv("YAP_VIDEO_NO_INTEROP")) {
			auto pb = reinterpret_cast<CVPixelBufferRef>(latest_hw_->data[3]);
			IOSurfaceRef surface = pb ? CVPixelBufferGetIOSurface(pb) : nullptr;
			OSType fmt = pb ? CVPixelBufferGetPixelFormatType(pb) : 0;
			if (latest_hw_->format == AV_PIX_FMT_VIDEOTOOLBOX && surface &&
			    (fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
			     fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)) {
				y = plane_texture(device_, surface, 0, MTLPixelFormatR8Unorm);
				uv = plane_texture(device_, surface, 1, MTLPixelFormatRG8Unorm);
				if (y && uv) {
					if (interop_state_.exchange(INTEROP_WORKS) != INTEROP_WORKS) {
						log(YV_LOG_INFO, "video: VideoToolbox's pictures go to Metal as IOSurfaces");
					}
					return true;
				}
				log(YV_LOG_INFO, "video: Metal won't take VideoToolbox's IOSurfaces");
			} else {
				log(YV_LOG_INFO, "video: VideoToolbox's frames aren't 8 bit NV12 in an IOSurface");
			}
		}
		interop_state_.store(INTEROP_NONE);
		AVFrame *sw = av_frame_alloc();
		const AVFrame *f = nullptr;
		if (sw && av_hwframe_transfer_data(sw, latest_hw_, 0) >= 0) {
			f = draw_nv12_.convert(sw);
		}
		if (f) {
			copy_planes(f);
		}
		av_frame_free(&sw);
		av_frame_free(&latest_hw_);
		if (!f) {
			latest_w_ = 0; // nothing to draw
		}
		return false;
	}

	// texture is `tex`, made again if it isn't w x h of `format` (or
	// isn't yet).
	id<MTLTexture> texture(id<MTLTexture> tex, MTLPixelFormat format, int w, int h,
	                       MTLTextureUsage usage, MTLStorageMode storage) {
		if (tex && static_cast<int>(tex.width) == w && static_cast<int>(tex.height) == h) {
			return tex;
		}
		MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
		                                                                                width:w
		                                                                               height:h
		                                                                            mipmapped:NO];
		desc.usage = usage;
		desc.storageMode = storage;
		return [device_ newTextureWithDescriptor:desc];
	}

	// draw converts the newest frame into rgba_. Called with mutex_ held.
	bool draw() {
		if (!pipeline_ && !make_pipeline()) {
			return false;
		}
		// The planes: the GPU frame's own, or uploaded.
		id<MTLTexture> y = nil, uv = nil;
		AVFrame *held = nullptr; // what y and uv lie in, till the GPU is done
		if (latest_hw_ && hw_planes(y, uv)) {
			held = av_frame_clone(latest_hw_);
		}
		int w = latest_w_, h = latest_h_, cw = (w + 1) / 2, ch = (h + 1) / 2;
		if (w <= 0) {
			return false;
		}
		if (!y) {
			// The last conversion's long done, a frame later; but it may
			// not be, and the planes are written by the CPU.
			[planes_read_ waitUntilCompleted];
			MTLStorageMode storage =
				device_.hasUnifiedMemory ? MTLStorageModeShared : MTLStorageModeManaged;
			plane_y_ = texture(plane_y_, MTLPixelFormatR8Unorm, w, h, MTLTextureUsageShaderRead,
			                   storage);
			plane_uv_ = texture(plane_uv_, MTLPixelFormatRG8Unorm, cw, ch,
			                    MTLTextureUsageShaderRead, storage);
			if (!plane_y_ || !plane_uv_) {
				return false;
			}
			[plane_y_ replaceRegion:MTLRegionMake2D(0, 0, w, h)
			            mipmapLevel:0
			              withBytes:latest_y_.data()
			            bytesPerRow:w];
			[plane_uv_ replaceRegion:MTLRegionMake2D(0, 0, cw, ch)
			             mipmapLevel:0
			               withBytes:latest_uv_.data()
			             bytesPerRow:cw * 2];
			y = plane_y_;
			uv = plane_uv_;
		}
		// The client's frames read it on the same queue, after this.
		rgba_ = texture(rgba_, MTLPixelFormatRGBA8Unorm, w, h,
		                MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget,
		                MTLStorageModePrivate);
		if (!rgba_) {
			log(YV_LOG_ERROR, "video: can't draw into a %dx%d texture", w, h);
			av_frame_free(&held);
			return false;
		}

		MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
		pass.colorAttachments[0].texture = rgba_;
		pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
		pass.colorAttachments[0].storeAction = MTLStoreActionStore;
		id<MTLCommandBuffer> cmd = [queue_ commandBuffer];
		id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
		[enc setRenderPipelineState:pipeline_];
		[enc setFragmentBytes:latest_matrix_.rows length:sizeof(latest_matrix_.rows) atIndex:0];
		[enc setFragmentTexture:y atIndex:0];
		[enc setFragmentTexture:uv atIndex:1];
		[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		[enc endEncoding];
		if (held) {
			// The decoder mustn't have the buffer back while it's read.
			[cmd addCompletedHandler:^(id<MTLCommandBuffer>) {
				AVFrame *f = held;
				av_frame_free(&f);
			}];
		} else {
			planes_read_ = cmd;
		}
		[cmd commit];
		return true;
	}
};

} // namespace

std::unique_ptr<Output> make_output() {
	return std::make_unique<Output_Metal>();
}

uint64_t gpu_luid(const yv_gpu *) {
	return 0;
}

} // namespace yv
