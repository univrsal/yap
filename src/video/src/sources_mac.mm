/*
Sources on macOS: ScreenCaptureKit's displays and windows. Nothing is
asked of it until the user has allowed Screen Recording, because asking
is what makes macOS prompt, and listing happens on its own (the client
does it as it starts) where a prompt would come out of nowhere.
yv_capture_allowed with `ask` is the one place that prompts.

SCShareableContent answers on a queue of its own, so waiting for it is
fine from any thread, the main one too.

On macOS 15 and later the system's picker (SCContentSharingPicker,
capture_mac.mm) is what the client offers: its share button opens it
straight away, and sharing source 0 is what does. 14 has the picker
too, but it's only from 15 that it's meant to spare the Screen
Recording permission our list needs, so it starts there (untried on
14). Our list is still there either way, for yv-loopback and those
who've allowed it; YAP_VIDEO_OUR_PICKER=1 says to use it in the client
too.
*/
#include "mac.h"

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

#include <cstdlib>
#include <unistd.h>

namespace yv {

SCShareableContent *shareable_content() {
	__block SCShareableContent *out = nil;
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	[SCShareableContent
		getShareableContentExcludingDesktopWindows:YES
		                       onScreenWindowsOnly:YES
		                         completionHandler:^(SCShareableContent *content, NSError *error) {
			                       if (error) {
				                       log(YV_LOG_WARN, "macOS won't list what can be captured: %s",
				                           error.localizedDescription.UTF8String);
			                       }
			                       out = content;
			                       dispatch_semaphore_signal(done);
		                         }];
	if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) {
		log(YV_LOG_WARN, "macOS didn't list what can be captured in time");
		return nil;
	}
	return out;
}

double pixels_per_point(CGDirectDisplayID display) {
	double scale = 1;
	CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
	CGRect bounds = CGDisplayBounds(display);
	if (mode && bounds.size.width > 0) {
		scale = static_cast<double>(CGDisplayModeGetPixelWidth(mode)) / bounds.size.width;
	}
	CGDisplayModeRelease(mode);
	return scale;
}

std::vector<yv_source> list_sources() {
	std::vector<yv_source> out;
	if (!CGPreflightScreenCaptureAccess()) {
		return out;
	}
	@autoreleasepool {
		SCShareableContent *content = shareable_content();
		if (!content) {
			return out;
		}
		CGDirectDisplayID main = CGMainDisplayID();
		int n = 0;
		for (SCDisplay *d in content.displays) {
			n++;
			yv_source s{};
			s.kind = YV_SOURCE_MONITOR;
			s.id = d.displayID;
			double scale = pixels_per_point(d.displayID);
			CGRect frame = d.frame;
			s.x = static_cast<int32_t>(frame.origin.x * scale);
			s.y = static_cast<int32_t>(frame.origin.y * scale);
			s.width = static_cast<int32_t>(frame.size.width * scale);
			s.height = static_cast<int32_t>(frame.size.height * scale);
			s.primary = d.displayID == main;
			std::string name = CGDisplayIsBuiltin(d.displayID)
			                       ? std::string("Built-in display")
			                       : "Display " + std::to_string(n);
			copy_name(s.name, sizeof(s.name), name);
			copy_name(s.app, sizeof(s.app), "display " + std::to_string(d.displayID));
			out.push_back(s);
		}
		double scale = pixels_per_point(main);
		pid_t me = getpid();
		for (SCWindow *w in content.windows) {
			// Ordinary windows with a title: not the menu bar, the Dock,
			// or the many small helper windows apps keep.
			if (w.windowLayer != 0 || w.title.length == 0 || !w.owningApplication ||
			    w.owningApplication.processID == me || w.frame.size.width < 2 ||
			    w.frame.size.height < 2) {
				continue;
			}
			yv_source s{};
			s.kind = YV_SOURCE_WINDOW;
			s.id = w.windowID;
			copy_name(s.name, sizeof(s.name), w.title.UTF8String);
			copy_name(s.app, sizeof(s.app), w.owningApplication.applicationName.UTF8String ?: "");
			s.x = static_cast<int32_t>(w.frame.origin.x * scale);
			s.y = static_cast<int32_t>(w.frame.origin.y * scale);
			s.width = static_cast<int32_t>(w.frame.size.width * scale);
			s.height = static_cast<int32_t>(w.frame.size.height * scale);
			out.push_back(s);
		}
	}
	return out;
}

bool system_picker() {
	if (const char *ours = getenv("YAP_VIDEO_OUR_PICKER"); ours && *ours == '1') {
		return false;
	}
	if (@available(macOS 15.0, *)) {
		return true;
	}
	return false;
}

bool capture_allowed(bool ask) {
	if (CGPreflightScreenCaptureAccess()) {
		return true;
	}
	return ask && CGRequestScreenCaptureAccess();
}

bool open_capture_settings() {
	@autoreleasepool {
		NSURL *url = [NSURL
			URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"];
		return [[NSWorkspace sharedWorkspace] openURL:url];
	}
}

} // namespace yv
