/*
Cameras on macOS, through AVFoundation: the built-in and USB cameras,
and an iPhone's (Continuity Camera) where the app's Info.plist says it
takes them (NSCameraUseContinuityCameraDeviceType, which
scripts/package-macos.sh sets).

Each of a camera's formats (AVCaptureDeviceFormat) is a mode, by its
index in the device's list (Camera_Mode.native). Whatever the camera
sends, the output is asked for NV12 ('420v', limited range): AVFoundation
converts on the way (and decodes MJPEG, which the macOS FFmpeg can't).
Frames arrive on a dispatch queue of the source's own, are read from the
CVPixelBuffer in memory and handed to camera.cpp from there.

macOS asks the user before the first use, once: starting a camera asks
if they haven't answered, and waits. After that only System Settings
(Privacy & Security, Camera) changes it. A process without
NSCameraUsageDescription in its Info.plist (or in its responsible app's,
Terminal's for one started from it) is killed when it asks, so the app
bundle has it, and yv-loopback carries one of its own.
YAP_VIDEO_FAKE_CAMERA's camera is listed first (camera_fake.cpp).
*/
// FFmpeg's `enum AVMediaType` and AVFoundation's share a name (see
// capture_mac.mm).
#define AVMediaType FFmpeg_AVMediaType
#include "pipeline.h"
#undef AVMediaType

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <thread>
#include <vector>

namespace yv {
namespace {

// What the output's queue hands frames to: the sink, and a buffer for a
// picture whose planes aren't one after the other.
struct Mac_Camera_Out {
	Camera_Sink *sink = nullptr;
	std::vector<uint8_t> packed;
	bool told_matrix = false;
};

} // namespace
} // namespace yv

@interface YVCameraOutput : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@end

@implementation YVCameraOutput {
@public
	yv::Mac_Camera_Out *out;
}

- (void)captureOutput:(AVCaptureOutput *)output
	didOutputSampleBuffer:(CMSampleBufferRef)sample
	       fromConnection:(AVCaptureConnection *)connection {
	CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sample);
	if (!pb || CVPixelBufferGetPixelFormatType(pb) != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
	    CVPixelBufferGetPlaneCount(pb) != 2 ||
	    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
		return;
	}
	int w = static_cast<int>(CVPixelBufferGetWidth(pb));
	int h = static_cast<int>(CVPixelBufferGetHeight(pb)) & ~1;
	const uint8_t *y = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(pb, 0));
	const uint8_t *uv = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(pb, 1));
	size_t y_stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
	size_t uv_stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
	size_t luma = y_stride * static_cast<size_t>(h);
	size_t size = luma + y_stride * static_cast<size_t>(h / 2);
	if (y && uv && w > 0 && h > 0) {
		yv::Camera_Frame f{yv::Camera_Format::NV12, w, h, y, size, false,
		                   static_cast<int>(y_stride)};
		// camera.cpp wants the chroma right after the luma, at the same stride.
		if (uv != y + luma || uv_stride != y_stride) {
			out->packed.resize(static_cast<size_t>(w) * static_cast<size_t>(h) * 3 / 2);
			uint8_t *dst = out->packed.data();
			for (int row = 0; row < h; row++) {
				memcpy(dst + static_cast<size_t>(row) * w, y + row * y_stride, static_cast<size_t>(w));
			}
			dst += static_cast<size_t>(w) * h;
			for (int row = 0; row < h / 2; row++) {
				memcpy(dst + static_cast<size_t>(row) * w, uv + row * uv_stride, static_cast<size_t>(w));
			}
			f.data = out->packed.data();
			f.size = out->packed.size();
			f.stride = w;
		}
		CFTypeRef matrix = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nullptr);
		f.bt709 = matrix && CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2);
		if (matrix) {
			CFRelease(matrix);
		}
		if (!out->told_matrix) {
			out->told_matrix = true;
			yv::log(YV_LOG_DEBUG, "camera: its colours are %s", f.bt709 ? "BT.709" : "BT.601");
		}
		out->sink->frame(f);
	}
	CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
}

@end

namespace yv {
namespace {

// The kinds of camera to list. Continuity Camera only where the app says it
// takes it; macOS 14 lists an iPhone as an external camera otherwise.
NSArray<AVCaptureDeviceType> *device_types() {
	NSMutableArray<AVCaptureDeviceType> *types =
		[NSMutableArray arrayWithObject:AVCaptureDeviceTypeBuiltInWideAngleCamera];
	if (@available(macOS 14.0, *)) {
		[types addObject:AVCaptureDeviceTypeExternal];
		id continuity = NSBundle.mainBundle.infoDictionary[@"NSCameraUseContinuityCameraDeviceType"];
		if ([continuity respondsToSelector:@selector(boolValue)] && [continuity boolValue]) {
			[types addObject:AVCaptureDeviceTypeContinuityCamera];
		}
	} else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
		[types addObject:AVCaptureDeviceTypeExternalUnknown];
#pragma clang diagnostic pop
	}
	return types;
}

NSArray<AVCaptureDevice *> *devices() {
	AVCaptureDeviceDiscoverySession *s =
		[AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:device_types()
	                                                           mediaType:AVMediaTypeVideo
	                                                            position:AVCaptureDevicePositionUnspecified];
	return s.devices;
}

AVCaptureDevice *device_with_id(const std::string &id) {
	for (AVCaptureDevice *d in devices()) {
		if (id == d.uniqueID.UTF8String) {
			return d;
		}
	}
	return nil;
}

// The format's range with the rate nearest `fps`, and that rate.
AVFrameRateRange *rate_for(AVCaptureDeviceFormat *format, double fps, double &got) {
	AVFrameRateRange *best = nil;
	double best_off = 0;
	for (AVFrameRateRange *r in format.videoSupportedFrameRateRanges) {
		double rate = std::clamp(fps, r.minFrameRate, r.maxFrameRate);
		double off = std::fabs(rate - fps);
		if (!best || off < best_off) {
			best = r;
			best_off = off;
			got = rate;
		}
	}
	return best;
}

bool wait_for_answer(const std::atomic<bool> *stop) {
	__block bool granted = false;
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	[AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
	                         completionHandler:^(BOOL ok) {
		                         granted = ok;
		                         dispatch_semaphore_signal(done);
	                         }];
	// The user may take a while; a share that's stopped meanwhile stops waiting.
	while (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0) {
		if (stop && stop->load()) {
			return false;
		}
	}
	return granted;
}

class Source_Mac final : public Camera_Source {
public:
	~Source_Mac() override {
		@autoreleasepool {
			[session_ stopRunning];
			[output_ setSampleBufferDelegate:nil queue:nil];
			// A frame being handed over finishes before the sink goes.
			if (queue_) {
				dispatch_sync(queue_, ^{
				});
			}
			if (locked_) {
				[device_ unlockForConfiguration];
			}
		}
	}

	bool open(const Camera_Info &camera, const Camera_Mode &mode, int, int, double fps,
	          Camera_Sink &sink, std::string &error) override {
		@autoreleasepool {
			out_.sink = &sink;
			device_ = device_with_id(camera.camera.id);
			if (!device_) {
				error = "that camera isn't there any more";
				return false;
			}
			NSError *err = nil;
			AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device_ error:&err];
			if (!input) {
				log(YV_LOG_WARN, "camera: %s", err.localizedDescription.UTF8String);
				error = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] ==
				                AVAuthorizationStatusAuthorized
				            ? "the camera won't open"
				            : "macOS doesn't let yap use the camera: allow it in System Settings, "
				              "Privacy & Security, Camera";
				return false;
			}
			session_ = [[AVCaptureSession alloc] init];
			if (![session_ canAddInput:input]) {
				error = "the camera won't open";
				return false;
			}
			[session_ addInput:input];

			output_ = [[AVCaptureVideoDataOutput alloc] init];
			output_.alwaysDiscardsLateVideoFrames = YES;
			output_.videoSettings = @{
				(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
			};
			delegate_ = [[YVCameraOutput alloc] init];
			delegate_->out = &out_;
			queue_ = dispatch_queue_create("yap.camera", DISPATCH_QUEUE_SERIAL);
			[output_ setSampleBufferDelegate:delegate_ queue:queue_];
			if (![session_ canAddOutput:output_]) {
				error = "the camera won't open";
				return false;
			}
			[session_ addOutput:output_];
			// What's sent is never mirrored; the self view mirrors it itself.
			AVCaptureConnection *conn = [output_ connectionWithMediaType:AVMediaTypeVideo];
			if (conn.supportsVideoMirroring) {
				conn.automaticallyAdjustsVideoMirroring = NO;
				conn.videoMirrored = NO;
			}

			// The format and rate go on the device once it's in the session, which
			// would otherwise set its own preset.
			NSArray<AVCaptureDeviceFormat *> *formats = device_.formats;
			if (mode.native >= formats.count || ![device_ lockForConfiguration:&err]) {
				error = "the camera won't take that format";
				return false;
			}
			locked_ = true;
			AVCaptureDeviceFormat *format = formats[mode.native];
			device_.activeFormat = format;
			double rate = fps;
			if (fps > 0 && rate_for(format, fps, rate)) {
				// As a fraction with room for 29.97.
				CMTime frame = CMTimeMake(1000, static_cast<int32_t>(std::lround(rate * 1000)));
				@try {
					device_.activeVideoMinFrameDuration = frame;
					device_.activeVideoMaxFrameDuration = frame;
				} @catch (NSException *e) {
					log(YV_LOG_INFO, "camera: it won't take %.2f fps: %s", rate, e.reason.UTF8String);
				}
			}
			// Started while locked, the session keeps the format instead of setting
			// its own preset.
			[session_ startRunning];
			[device_ unlockForConfiguration];
			locked_ = false;
			if (!session_.running) {
				error = device_.inUseByAnotherApplication ? "another program is using the camera"
				                                          : "the camera won't start";
				return false;
			}
			return true;
		}
	}

private:
	Mac_Camera_Out out_;
	AVCaptureDevice *device_ = nil;
	AVCaptureSession *session_ = nil;
	AVCaptureVideoDataOutput *output_ = nil;
	YVCameraOutput *delegate_ = nil;
	dispatch_queue_t queue_ = nil;
	bool locked_ = false;
};

} // namespace

std::vector<Camera_Info> list_cameras() {
	std::vector<Camera_Info> out;
	Camera_Info fake;
	if (fake_camera(fake)) {
		out.push_back(fake);
	}
	@autoreleasepool {
		for (AVCaptureDevice *d in devices()) {
			Camera_Info info;
			copy_name(info.camera.id, sizeof(info.camera.id), d.uniqueID.UTF8String);
			copy_name(info.camera.name, sizeof(info.camera.name), d.localizedName.UTF8String ?: "");
			info.name = info.camera.name;
			info.path = info.camera.id;
			info.camera.front = d.position == AVCaptureDevicePositionFront ||
			                    [d.deviceType isEqualToString:AVCaptureDeviceTypeBuiltInWideAngleCamera];
			NSArray<AVCaptureDeviceFormat *> *formats = d.formats;
			for (NSUInteger i = 0; i < formats.count; i++) {
				AVCaptureDeviceFormat *f = formats[i];
				if (CMFormatDescriptionGetMediaType(f.formatDescription) != kCMMediaType_Video) {
					continue;
				}
				CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription);
				Camera_Mode m;
				m.min_width = m.max_width = dim.width;
				m.min_height = m.max_height = dim.height;
				// What it is to us: the output always asks for NV12.
				m.format = Camera_Format::NV12;
				m.native = static_cast<uint32_t>(i);
				for (AVFrameRateRange *r in f.videoSupportedFrameRateRanges) {
					m.max_fps = std::max(m.max_fps, r.maxFrameRate);
					m.min_fps = m.min_fps > 0 ? std::min(m.min_fps, r.minFrameRate) : r.minFrameRate;
				}
				if (m.max_width <= 0 || m.max_height <= 0) {
					continue;
				}
				// Formats that differ only in what the camera sends are one mode to us.
				bool seen = std::any_of(info.modes.begin(), info.modes.end(), [&](const Camera_Mode &o) {
					return o.max_width == m.max_width && o.max_height == m.max_height &&
					       o.max_fps >= m.max_fps && o.min_fps <= m.min_fps;
				});
				if (!seen) {
					info.modes.push_back(m);
				}
			}
			if (info.modes.empty()) {
				continue;
			}
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
	}
	return out;
}

bool camera_allowed(bool ask, const std::atomic<bool> *stop) {
	switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo]) {
	case AVAuthorizationStatusAuthorized:
		return true;
	case AVAuthorizationStatusNotDetermined:
		// Not answered yet: allowed as far as anyone knows, until it's asked.
		return ask ? wait_for_answer(stop) : true;
	default:
		return false;
	}
}

std::unique_ptr<Camera_Source> make_camera_source(const Camera_Info &camera) {
	if (strcmp(camera.camera.id, FAKE_CAMERA_ID) == 0) {
		return make_fake_source();
	}
	return std::make_unique<Source_Mac>();
}

} // namespace yv
