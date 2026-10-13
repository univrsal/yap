// What the macOS parts share (Objective-C++ only).
#pragma once

#include "internal.h"

#import <ScreenCaptureKit/ScreenCaptureKit.h>

namespace yv {

// shareable_content waits for ScreenCaptureKit's list of what can be
// captured; nil if it won't say (not allowed, or no answer in time).
SCShareableContent *shareable_content();

// How many pixels a point is on `display`: 2 on a Retina display.
double pixels_per_point(CGDirectDisplayID display);

} // namespace yv
