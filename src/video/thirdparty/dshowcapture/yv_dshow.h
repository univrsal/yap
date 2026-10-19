/*
yv_dshow: the plain C face of dshowcapture.dll, which is libdshowcapture
(LGPL, in this folder) with yv_dshow.cpp, for yap_video's cameras on
Windows (src/video/src/camera_win.cpp).

libdshowcapture's own interface is C++ (std::vector, std::function),
which can't cross between two DLLs that each have their own static C
runtime and so their own heap. Everything here is fixed size structs
and plain functions instead. yap_video loads the DLL at run time and
finds these by name; it goes on without cameras if it isn't there.

libdshowcapture is upstream's (github.com/obsproject/libdshowcapture)
without its Visual Studio project and its submodule, Elgato's
capture-device-support, and with two changes, marked "yap:": Elgato's
HDR tonemapper is left out (source/device-vendor.cpp), and frames
without time stamps are passed on too (source/device.cpp), which wine's
cameras send.
*/
#ifndef YV_DSHOW_H
#define YV_DSHOW_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef YV_DSHOW_BUILDING
#define YV_DSHOW_API __declspec(dllexport)
#else
#define YV_DSHOW_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

// yvds_version's, which yap_video checks before using anything else.
#define YVDS_VERSION 1

// What the pictures are, as libdshowcapture's DShow::VideoFormat.
typedef enum yvds_format {
	YVDS_ARGB = 100,
	YVDS_XRGB = 101,
	YVDS_RGB24 = 102,
	YVDS_I420 = 200,
	YVDS_NV12 = 201,
	YVDS_YV12 = 202,
	YVDS_Y800 = 203,
	YVDS_YVYU = 300,
	YVDS_YUY2 = 301,
	YVDS_UYVY = 302,
	YVDS_HDYC = 303,
	YVDS_MJPEG = 400,
} yvds_format;

// A way a camera can capture: a size, or sizes in steps, at frame
// intervals in 100 ns units.
typedef struct yvds_mode {
	int32_t min_width, min_height, max_width, max_height;
	int32_t step_width, step_height;
	int64_t min_interval, max_interval;
	int32_t format; // yvds_format, or another of DShow::VideoFormat's
} yvds_mode;

#define YVDS_MAX_MODES 128

typedef struct yvds_device {
	char name[256]; // UTF-8
	char path[512]; // empty for a virtual camera, which goes by its name
	int32_t modes_n;
	yvds_mode modes[YVDS_MAX_MODES];
} yvds_device;

typedef struct yvds_frame {
	int32_t format; // yvds_format
	int32_t width, height;
	bool flip; // the rows are bottom-up (an RGB DIB)
	const uint8_t *data; // valid during the call only
	size_t size;
	int64_t start; // the device's time stamp, in 100 ns units
} yvds_frame;

// Called from DirectShow's streaming thread, one frame at a time.
typedef void (*yvds_frame_fn)(void *user, const yvds_frame *frame);

typedef struct yvds_open_config {
	const char *name; // yvds_device's
	const char *path;
	int32_t width, height;
	int64_t interval;
	int32_t format;
	yvds_frame_fn frame;
	void *user;
} yvds_open_config;

typedef enum yvds_result {
	YVDS_OK = 0,
	YVDS_IN_USE = 1, // another program has the camera
	YVDS_ERROR = 2,
} yvds_result;

// level: 0 debug, 1 info, 2 warning, 3 error; `msg` is UTF-8, valid
// during the call only.
typedef void (*yvds_log_fn)(void *user, int level, const char *msg);

typedef struct yvds_camera yvds_camera;

YV_DSHOW_API int yvds_version(void);
// Sets where libdshowcapture's messages go, for the whole process.
YV_DSHOW_API void yvds_set_log(yvds_log_fn fn, void *user);
/*
yvds_list fills `out` with up to `max` cameras and says how many there
are. COM has to be initialized on the calling thread.
*/
YV_DSHOW_API int yvds_list(yvds_device *out, int max);
/*
yvds_open opens a camera and starts it; NULL with *result saying why
if it can't. COM has to be initialized on the calling thread, which
yvds_close is called from too.
*/
YV_DSHOW_API yvds_camera *yvds_open(const yvds_open_config *config, yvds_result *result);
// Stops the camera: once this returns, `frame` isn't called any more.
YV_DSHOW_API void yvds_close(yvds_camera *camera);

#ifdef __cplusplus
}
#endif

#endif
