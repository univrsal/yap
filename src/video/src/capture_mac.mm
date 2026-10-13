/*
Capturing on macOS with ScreenCaptureKit (macOS 12.3 and later).

The stream is asked for NV12 ('420v': BT.709, limited range) at the size
the share will encode, so ScreenCaptureKit does the colour conversion
and the scaling on the GPU, and what it hands over is an IOSurface
backed CVPixelBuffer the VideoToolbox encoders take as it is: the
picture never comes through memory. Encoders that want memory (and
YAP_VIDEO_SOFTWARE) get it read back, and scaled by swscale if the
size is off (a window that was resized: the stream keeps the size it
started with and fits the window into it).

It only sends frames when something changed (SCFrameStatusComplete);
idle ones are skipped. Our own app's windows are left out of a display.

On macOS 15 and later, sharing source 0 asks with the system's picker
(SCContentSharingPicker) instead of our list: what's chosen there is
what's captured. The picker is the system's UI, so it's shown from the
main thread's queue, which the client's event loop runs.
*/
// FFmpeg's `enum AVMediaType` and AVFoundation's `AVMediaType` (which
// ScreenCaptureKit brings in) share a name, so here FFmpeg's goes by
// another while its headers are read. Its functions are C, so the name
// doesn't reach the library; nothing here uses it.
#define AVMediaType FFmpeg_AVMediaType
#include "pipeline.h"
extern "C" {
#include <libavutil/hwcontext.h>
#include <libswscale/swscale.h>
}
#undef AVMediaType

#include "mac.h"

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <memory>
#include <unistd.h>

namespace yv {

// What the stream's queue and the share's thread share.
struct Mac_Frames {
	std::mutex mutex;
	std::condition_variable cv;
	CVPixelBufferRef pending = nullptr; // newest, not yet taken
	bool closed = false;

	~Mac_Frames() {
		CVPixelBufferRelease(pending);
	}

	void put(CVPixelBufferRef pb) {
		CVPixelBufferRetain(pb);
		std::lock_guard<std::mutex> lock(mutex);
		CVPixelBufferRelease(pending);
		pending = pb;
		cv.notify_one();
	}

	void close() {
		std::lock_guard<std::mutex> lock(mutex);
		closed = true;
		cv.notify_one();
	}
};

} // namespace yv

@interface YVStreamOutput : NSObject <SCStreamOutput, SCStreamDelegate>
@end

@implementation YVStreamOutput {
@public
	std::shared_ptr<yv::Mac_Frames> frames;
}

- (void)stream:(SCStream *)stream
	didOutputSampleBuffer:(CMSampleBufferRef)sample
	               ofType:(SCStreamOutputType)type {
	if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sample)) {
		return;
	}
	CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
	if (!attachments || CFArrayGetCount(attachments) < 1) {
		return;
	}
	NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(attachments, 0);
	NSNumber *status = info[SCStreamFrameInfoStatus];
	if (!status || status.integerValue != SCFrameStatusComplete) {
		return; // idle, blank or suspended: nothing new
	}
	CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sample);
	if (pb) {
		frames->put(pb);
	}
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
	yv::log(YV_LOG_INFO, "share: capture stopped: %s", error.localizedDescription.UTF8String);
	frames->close();
}

@end

// The system picker's answer, for the share's thread waiting for it.
API_AVAILABLE(macos(14.0))
@interface YVPickerObserver : NSObject <SCContentSharingPickerObserver>
@end

@implementation YVPickerObserver {
@public
	dispatch_semaphore_t done;
	SCContentFilter *filter;
	bool cancelled;
	std::string error;
}

- (void)contentSharingPicker:(SCContentSharingPicker *)picker
         didUpdateWithFilter:(SCContentFilter *)picked
                   forStream:(SCStream *)stream {
	if (!filter) {
		filter = picked;
		dispatch_semaphore_signal(done);
	}
}

- (void)contentSharingPicker:(SCContentSharingPicker *)picker didCancelForStream:(SCStream *)stream {
	cancelled = true;
	dispatch_semaphore_signal(done);
}

- (void)contentSharingPickerStartDidFailWithError:(NSError *)failure {
	error = failure.localizedDescription.UTF8String ?: "the picker failed";
	dispatch_semaphore_signal(done);
}

@end

namespace yv {

namespace {

/*
pick shows the system's picker and waits for what's chosen there, or
nil: the user cancelled (`cancelled`), the share was stopped, or the
picker failed (`error`).
*/
API_AVAILABLE(macos(14.0))
SCContentFilter *pick(const std::atomic<bool> &stop, bool &cancelled, std::string &error) {
	YVPickerObserver *obs = [[YVPickerObserver alloc] init];
	obs->done = dispatch_semaphore_create(0);
	dispatch_async(dispatch_get_main_queue(), ^{
	  SCContentSharingPicker *picker = SCContentSharingPicker.sharedPicker;
	  SCContentSharingPickerConfiguration *conf = [[SCContentSharingPickerConfiguration alloc] init];
	  conf.allowedPickerModes =
		  SCContentSharingPickerModeSingleWindow | SCContentSharingPickerModeSingleDisplay;
	  picker.defaultConfiguration = conf;
	  [picker addObserver:obs];
	  picker.active = YES;
	  [picker present];
	});
	bool stopped = false;
	while (dispatch_semaphore_wait(obs->done, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC)) !=
	       0) {
		if (stop.load()) {
			stopped = true;
			break;
		}
	}
	SCContentFilter *filter = stopped ? nil : obs->filter;
	dispatch_async(dispatch_get_main_queue(), ^{
	  SCContentSharingPicker *picker = SCContentSharingPicker.sharedPicker;
	  [picker removeObserver:obs];
	  if (!filter) {
		  picker.active = NO; // takes it down, if it's still up
	  }
	});
	if (!filter) {
		cancelled = !stopped && obs->cancelled;
		error = stopped              ? "stopped before anything was chosen"
		        : obs->cancelled     ? "sharing was cancelled"
		        : obs->error.empty() ? "nothing was chosen"
		                             : obs->error;
	}
	return filter;
}

void release_pixel_buffer(void *, uint8_t *data) {
	CVPixelBufferRelease(reinterpret_cast<CVPixelBufferRef>(data));
}

// The same fitting as share.cpp's, so the stream comes at the size the
// encoder will be.
void fit(int w, int h, int max_w, int max_h, int &out_w, int &out_h) {
	double s = 1.0;
	if (max_w > 0 && w > max_w) {
		s = std::min(s, static_cast<double>(max_w) / w);
	}
	if (max_h > 0 && h > max_h) {
		s = std::min(s, static_cast<double>(max_h) / h);
	}
	out_w = std::max(2, static_cast<int>(w * s) & ~1);
	out_h = std::max(2, static_cast<int>(h * s) & ~1);
}

class Pipeline_Mac : public Pipeline {
public:
	~Pipeline_Mac() override {
		if (stream_) {
			dispatch_semaphore_t done = dispatch_semaphore_create(0);
			[stream_ stopCaptureWithCompletionHandler:^(NSError *) {
			  dispatch_semaphore_signal(done);
			}];
			dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
			[stream_ removeStreamOutput:output_ type:SCStreamOutputTypeScreen error:nil];
		}
		stream_ = nil;
		output_ = nil;
		CVPixelBufferRelease(latest_);
		sws_freeContext(sws_);
		av_frame_free(&nv12_);
		av_buffer_unref(&device_);
	}

	bool cancelled() override {
		return cancelled_;
	}

	bool open(const yv_share_config &config, const char *encoder, const std::atomic<bool> &stop,
	          std::string &error) override {
		@autoreleasepool {
			SCContentFilter *filter = nil;
			int w = 0, h = 0;
			if (config.source == 0 && system_picker()) {
				if (@available(macOS 14.0, *)) {
					filter = pick(stop, cancelled_, error);
					if (!filter) {
						return false;
					}
					double scale = filter.pointPixelScale;
					w = static_cast<int>(filter.contentRect.size.width * scale);
					h = static_cast<int>(filter.contentRect.size.height * scale);
				}
			} else if (!our_filter(config, filter, w, h, error)) {
				return false;
			}
			fit(w, h, config.max_width, config.max_height, w, h);

			SCStreamConfiguration *cfg = [[SCStreamConfiguration alloc] init];
			cfg.width = static_cast<size_t>(w);
			cfg.height = static_cast<size_t>(h);
			cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
			cfg.colorMatrix = kCGDisplayStreamYCbCrMatrix_ITU_R_709_2;
			cfg.minimumFrameInterval = CMTimeMake(1, std::max(1, config.fps));
			cfg.queueDepth = 4;
			cfg.showsCursor = config.cursor;

			frames_ = std::make_shared<Mac_Frames>();
			output_ = [[YVStreamOutput alloc] init];
			output_->frames = frames_;
			stream_ = [[SCStream alloc] initWithFilter:filter configuration:cfg delegate:output_];
			queue_ = dispatch_queue_create("yap.capture", DISPATCH_QUEUE_SERIAL);
			NSError *err = nil;
			if (![stream_ addStreamOutput:output_
			                         type:SCStreamOutputTypeScreen
			           sampleHandlerQueue:queue_
			                        error:&err]) {
				error = std::string("can't capture: ") + err.localizedDescription.UTF8String;
				stream_ = nil;
				return false;
			}
			__block NSError *start_err = nil;
			dispatch_semaphore_t started = dispatch_semaphore_create(0);
			[stream_ startCaptureWithCompletionHandler:^(NSError *e) {
			  start_err = e;
			  dispatch_semaphore_signal(started);
			}];
			if (dispatch_semaphore_wait(started, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) !=
			        0 ||
			    start_err) {
				error = std::string("can't capture: ") +
				        (start_err ? start_err.localizedDescription.UTF8String : "no answer");
				[stream_ removeStreamOutput:output_ type:SCStreamOutputTypeScreen error:nil];
				stream_ = nil;
				return false;
			}
			log(YV_LOG_INFO, "share: capturing %s %llu at %dx%d with ScreenCaptureKit",
			    config.kind == YV_SOURCE_MONITOR ? "display" : "window",
			    static_cast<unsigned long long>(config.source), w, h);
		}
		if (strstr(encoder, "_videotoolbox") &&
		    av_hwdevice_ctx_create(&device_, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nullptr, nullptr, 0) <
		        0) {
			device_ = nullptr;
		}
		return true;
	}

	bool wait(int ms, bool &closed) override {
		CVPixelBufferRef pb = nullptr;
		{
			std::unique_lock<std::mutex> lock(frames_->mutex);
			frames_->cv.wait_for(lock, std::chrono::milliseconds(ms),
			                     [this] { return frames_->pending || frames_->closed; });
			closed = frames_->closed;
			pb = frames_->pending;
			frames_->pending = nullptr;
		}
		if (!pb) {
			return false;
		}
		CVPixelBufferRelease(latest_);
		latest_ = pb; // the reference put() took
		return true;
	}

	int width() override {
		return latest_ ? static_cast<int>(CVPixelBufferGetWidth(latest_)) : 0;
	}

	int height() override {
		return latest_ ? static_cast<int>(CVPixelBufferGetHeight(latest_)) : 0;
	}

	AVBufferRef *hw_device() override {
		return device_ ? av_buffer_ref(device_) : nullptr;
	}

	AVBufferRef *hw_frames(int w, int h) override {
		if (!device_) {
			return nullptr;
		}
		AVBufferRef *ref = av_hwframe_ctx_alloc(device_);
		if (!ref) {
			return nullptr;
		}
		auto *fc = reinterpret_cast<AVHWFramesContext *>(ref->data);
		fc->format = AV_PIX_FMT_VIDEOTOOLBOX;
		fc->sw_format = AV_PIX_FMT_NV12;
		fc->width = w;
		fc->height = h;
		fc->initial_pool_size = 0;
		if (av_hwframe_ctx_init(ref) < 0) {
			av_buffer_unref(&ref);
			return nullptr;
		}
		return ref;
	}

	bool convert(AVFrame *out, AVBufferRef *frames, int w, int h) override {
		if (!latest_) {
			return false;
		}
		bool same = width() == w && height() == h &&
		            CVPixelBufferGetPixelFormatType(latest_) ==
		                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
		if (frames && same) {
			// The captured buffer itself, for VideoToolbox.
			CVPixelBufferRetain(latest_);
			out->buf[0] = av_buffer_create(reinterpret_cast<uint8_t *>(latest_), 0,
			                               release_pixel_buffer, nullptr, AV_BUFFER_FLAG_READONLY);
			if (!out->buf[0]) {
				CVPixelBufferRelease(latest_);
				return false;
			}
			out->data[3] = reinterpret_cast<uint8_t *>(latest_);
			out->format = AV_PIX_FMT_VIDEOTOOLBOX;
			out->width = w;
			out->height = h;
			out->hw_frames_ctx = av_buffer_ref(frames);
			return out->hw_frames_ctx != nullptr;
		}
		AVFrame *sw = frames ? nv12() : out;
		if (!read_back(sw, w, h)) {
			return false;
		}
		if (!frames) {
			return true;
		}
		if (av_hwframe_get_buffer(frames, out, 0) < 0 || av_hwframe_transfer_data(out, sw, 0) < 0) {
			av_frame_unref(out);
			return false;
		}
		return true;
	}

private:
	bool cancelled_ = false;
	std::shared_ptr<Mac_Frames> frames_;
	YVStreamOutput *output_ = nil;
	SCStream *stream_ = nil;
	dispatch_queue_t queue_ = nil;
	CVPixelBufferRef latest_ = nullptr;
	AVBufferRef *device_ = nullptr;
	SwsContext *sws_ = nullptr;
	AVFrame *nv12_ = nullptr;

	/*
	our_filter finds what `config` names in ScreenCaptureKit's list (a
	display without our own windows, or a window), and its size in
	pixels. Needs Screen Recording allowed.
	*/
	bool our_filter(const yv_share_config &config, SCContentFilter *__strong &filter, int &w,
	                int &h, std::string &error) {
		if (!CGPreflightScreenCaptureAccess()) {
			error = "macOS hasn't allowed yap to record the screen (System Settings, Privacy & "
			        "Security, Screen Recording)";
			return false;
		}
		SCShareableContent *content = shareable_content();
		if (!content) {
			error = "macOS won't say what can be captured";
			return false;
		}
		if (config.kind == YV_SOURCE_MONITOR) {
			SCDisplay *display = nil;
			for (SCDisplay *d in content.displays) {
				if (d.displayID == config.source) {
					display = d;
				}
			}
			if (!display) {
				error = "that display isn't there any more";
				return false;
			}
			NSMutableArray<SCRunningApplication *> *ours = [NSMutableArray array];
			for (SCRunningApplication *app in content.applications) {
				if (app.processID == getpid()) {
					[ours addObject:app];
				}
			}
			filter = [[SCContentFilter alloc] initWithDisplay:display
			                            excludingApplications:ours
			                                 exceptingWindows:@[]];
			double scale = pixels_per_point(display.displayID);
			w = static_cast<int>(display.frame.size.width * scale);
			h = static_cast<int>(display.frame.size.height * scale);
		} else {
			SCWindow *window = nil;
			for (SCWindow *win in content.windows) {
				if (win.windowID == config.source) {
					window = win;
				}
			}
			if (!window) {
				error = "that window isn't there any more";
				return false;
			}
			filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:window];
			double scale = pixels_per_point(CGMainDisplayID());
			if (@available(macOS 14.0, *)) {
				scale = filter.pointPixelScale;
			}
			w = static_cast<int>(window.frame.size.width * scale);
			h = static_cast<int>(window.frame.size.height * scale);
		}
		return true;
	}

	AVFrame *nv12() {
		if (!nv12_) {
			nv12_ = av_frame_alloc();
		}
		av_frame_unref(nv12_);
		return nv12_;
	}

	// read_back copies (and scales) the latest capture into `out`, an
	// NV12 frame in memory of w x h.
	bool read_back(AVFrame *out, int w, int h) {
		if (CVPixelBufferGetPixelFormatType(latest_) !=
		        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
		    CVPixelBufferGetPlaneCount(latest_) != 2) {
			return false;
		}
		out->format = AV_PIX_FMT_NV12;
		out->width = w;
		out->height = h;
		if (av_frame_get_buffer(out, 0) < 0) {
			return false;
		}
		int sw = width(), sh = height();
		sws_ = sws_getCachedContext(sws_, sw, sh, AV_PIX_FMT_NV12, w, h, AV_PIX_FMT_NV12,
		                            (w < sw || h < sh) ? SWS_AREA : SWS_BILINEAR, nullptr, nullptr,
		                            nullptr);
		if (!sws_ || CVPixelBufferLockBaseAddress(latest_, kCVPixelBufferLock_ReadOnly) != 0) {
			return false;
		}
		const uint8_t *src[2] = {
			static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(latest_, 0)),
			static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(latest_, 1)),
		};
		const int stride[2] = {
			static_cast<int>(CVPixelBufferGetBytesPerRowOfPlane(latest_, 0)),
			static_cast<int>(CVPixelBufferGetBytesPerRowOfPlane(latest_, 1)),
		};
		bool ok = sws_scale(sws_, src, stride, 0, sh, out->data, out->linesize) == h;
		CVPixelBufferUnlockBaseAddress(latest_, kCVPixelBufferLock_ReadOnly);
		return ok;
	}
};

} // namespace

std::unique_ptr<Pipeline> make_pipeline() {
	return std::make_unique<Pipeline_Mac>();
}

} // namespace yv
