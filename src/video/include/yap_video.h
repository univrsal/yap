/*
yap_video: capture, encoding and decoding for screen sharing and
cameras in the native client (misc/hq-share/README.md,
misc/video-chat/README.md). The client loads it at runtime
if it's there; nothing here knows about networks or yap's protocol:
encoded frames go out, encoded frames come in.

Everything is plain C so Odin can bind it with core:dynlib. Structs are
fixed size, strings are UTF-8 in fixed buffers, and a struct only ever
grows at the end, with YV_API_VERSION bumped when it does.
*/
#ifndef YAP_VIDEO_H
#define YAP_VIDEO_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef _WIN32
#ifdef YV_BUILDING
#define YV_API __declspec(dllexport)
#else
#define YV_API __declspec(dllimport)
#endif
#else
#define YV_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// What a client was built against. yv_create refuses any other.
#define YV_API_VERSION 9

typedef struct yv_context yv_context;

typedef enum yv_log_level {
	YV_LOG_DEBUG = 0,
	YV_LOG_INFO = 1,
	YV_LOG_WARN = 2,
	YV_LOG_ERROR = 3,
} yv_log_level;

// Which graphics API the client draws with, so the library can hand it
// textures it can draw (yv_set_gpu).
typedef enum yv_gpu_kind {
	YV_GPU_NONE = 0,
	YV_GPU_D3D11 = 1,
	YV_GPU_GL = 2,
	YV_GPU_METAL = 3,
} yv_gpu_kind;

// The numbers are the codec byte of a video fragment (proto.Video_Codec).
typedef enum yv_codec {
	YV_CODEC_H264 = 0,
	YV_CODEC_HEVC = 1,
	YV_CODEC_AV1 = 2,
} yv_codec;

// Called from any of the library's threads, so it has to be thread safe.
// `msg` is only valid during the call and has no trailing newline.
typedef void (*yv_log_fn)(void *user, yv_log_level level, const char *msg);

typedef struct yv_init {
	uint32_t api_version; // YV_API_VERSION
	yv_log_fn log;        // may be NULL
	void *log_user;
	yv_log_level log_level; // what's below this isn't passed on
} yv_init;

/*
yv_create makes the library's context. NULL if api_version doesn't
match; the reason went to the log.
*/
YV_API yv_context *yv_create(const yv_init *init);
YV_API void yv_destroy(yv_context *ctx);

// The library's own YV_API_VERSION, to check before calling yv_create.
YV_API uint32_t yv_api_version(void);
// A version string for logs and the about box, e.g. "1 (FFmpeg 9.0)".
YV_API const char *yv_version_string(void);

typedef enum yv_source_kind {
	YV_SOURCE_MONITOR = 0,
	YV_SOURCE_WINDOW = 1,
} yv_source_kind;

#define YV_NAME_SIZE 256

typedef struct yv_source {
	yv_source_kind kind;
	// What to pass back to share it: an HMONITOR or HWND on Windows, a
	// window's XID or a monitor's rectangle on X11, a CGDirectDisplayID
	// or CGWindowID on macOS. It only means something until the
	// monitors or windows change.
	uint64_t id;
	char name[YV_NAME_SIZE]; // monitor model or window title
	char app[YV_NAME_SIZE];  // the window's executable; for a monitor, its device name
	int32_t x, y;            // where on the desktop, in pixels
	int32_t width, height;   // in pixels
	bool primary;            // the primary monitor
} yv_source;

/*
yv_list_sources fills `out` with up to `max` monitors (first) and
windows, and says how many there are in all, which may be more than
`max`. Windows of this process are left out. Nothing, while capturing
isn't allowed (yv_capture_allowed).
*/
YV_API int yv_list_sources(yv_context *ctx, yv_source *out, int max);

/*
Whether the operating system shows its own picker instead of ours
(Wayland's portal, macOS 15's SCContentSharingPicker): sharing source 0
(a monitor) opens it, and captures what's chosen there. On Wayland
that's all yv_list_sources lists; on macOS the usual list is there
too, but needs Screen Recording allowed (yv_capture_allowed), which the
picker doesn't.
*/
YV_API bool yv_system_picker(yv_context *ctx);

/*
Whether this process may capture the screen. On macOS that's up to the
user (System Settings, Privacy & Security, Screen Recording); `ask`
shows the system's prompt for it, which macOS only does the first time,
and once it's been allowed the process has to be started again before
it counts. Everywhere else, always true.
*/
YV_API bool yv_capture_allowed(yv_context *ctx, bool ask);

// Opens the system's settings where capturing is allowed, if there are
// any (macOS); false where there's nothing to open.
YV_API bool yv_open_capture_settings(yv_context *ctx);

typedef struct yv_encoder {
	char name[64];   // FFmpeg's name, e.g. "av1_nvenc"; what settings store
	char label[128]; // for people, e.g. "AV1 (NVIDIA NVENC)"
	yv_codec codec;
	bool hardware;
	bool works; // opened and encoded a test frame
} yv_encoder;

/*
yv_list_encoders fills `out` with up to `max` encoders, best first (AV1,
then HEVC, then H.264; hardware before software), and says how many
there are. The first call tries each one on a small test frame, which
can take a second; later calls return what it found.
*/
YV_API int yv_list_encoders(yv_context *ctx, yv_encoder *out, int max);

/*
The client's graphics device, which the pictures of yv_view_present are
made for. Call it from the thread that draws, before presenting, and
again with NULL (or YV_GPU_NONE) before that device goes: the library
then lets go of everything it made on it.

D3D11: the client's ID3D11Device. It's only used from the thread that
calls yv_set_gpu and yv_view_present, so a SINGLETHREADED device is fine.
GL: the client's context has to be current on that thread whenever
these are called; gl_get_proc finds its functions (glfwGetProcAddress).
Metal: the client's id<MTLDevice>, and the id<MTLCommandQueue> it draws
its frames with. The pictures are made on that queue, so the client's
frames that draw them, committed after yv_view_present, find them done.
*/
typedef struct yv_gpu {
	yv_gpu_kind kind;
	void *d3d11_device;
	void *(*gl_get_proc)(const char *name);
	void *metal_device;
	void *metal_queue;
} yv_gpu;

YV_API void yv_set_gpu(yv_context *ctx, const yv_gpu *gpu);

/*
Watching: a view decodes one stream of encoded frames, on a thread of its
own, and keeps the newest picture for yv_view_present. The decoder is
made on the first keyframe and made again whenever the codec changes;
frames before a keyframe are dropped.
*/
typedef struct yv_view yv_view;

YV_API yv_view *yv_view_create(yv_context *ctx);
// Not while another thread is still in a call on the view.
YV_API void yv_view_destroy(yv_view *view);

/*
yv_view_push hands a whole encoded frame (an H.264 or HEVC access unit
in Annex B, an AV1 temporal unit) to the decoder; it's copied, so
`data` is the caller's again on return. Any thread. `pts_us` is only
passed through, for statistics.
*/
YV_API void yv_view_push(yv_view *view, const uint8_t *data, size_t size, yv_codec codec,
                         uint64_t pts_us, bool key);

// yv_view_clear drops the decoder and the picture: someone else's
// stream comes next, or none. Any thread.
YV_API void yv_view_clear(yv_view *view);

/*
yv_view_take_failed says, once, that the decoder gave up (a frame
missing, a broken stream, more frames than it can keep up with). It
then waits for a keyframe, which the caller should ask the sharer for.
Any thread.
*/
YV_API bool yv_view_take_failed(yv_view *view);

/*
yv_view_on_frame has `fn` called each time a new picture is ready for
yv_view_present, from the view's decoder thread: for a UI that only
draws when something changed to wake up. NULL for no more calls; once
it returns, the old `fn` isn't being called any more.
*/
typedef void (*yv_frame_fn)(void *user);
YV_API void yv_view_on_frame(yv_view *view, yv_frame_fn fn, void *user);

typedef struct yv_picture {
	// What the client draws: an ID3D11ShaderResourceView* (D3D11), an
	// OpenGL texture name (GL) or an id<MTLTexture> (Metal) of an RGBA
	// texture, made on the device of yv_set_gpu. The library's; valid until the next
	// yv_view_present or yv_set_gpu.
	uintptr_t texture;
	int32_t width, height;
	uint64_t frames; // decoded since the view was made or cleared
	bool hardware;   // decoded by the GPU
	uint64_t pts_us; // the pts_us it was pushed with
} yv_picture;

/*
yv_view_present brings the newest decoded picture over to the client's
device, if a new one came, and describes it. False while there's no
picture yet (or no GPU). From the thread of yv_set_gpu.
*/
YV_API bool yv_view_present(yv_view *view, yv_picture *out);

/*
Sharing: a share captures a monitor or a window and encodes it, on a
thread of its own, until it's stopped. Encoded frames wait to be pulled
(a few at most: one that isn't pulled in time is dropped, and the next
one is a keyframe).
*/
typedef struct yv_share yv_share;

typedef struct yv_share_config {
	yv_source_kind kind;
	uint64_t source; // yv_source.id
	// yv_encoder.name, or "" for the best that works.
	char encoder[64];
	int32_t fps;                   // at most this many frames a second
	int32_t max_width, max_height; // scaled down to fit, keeping its shape; 0 for no limit
	uint32_t kbit;                 // the bitrate, in kbit/s
	bool cursor;                   // the mouse pointer in the picture
	/*
	What the viewers can decode, as bits (1 << yv_codec); 0 for anything.
	With encoder "", the best that works is the best of these, and
	yv_share_set_codecs changes it as viewers come and go. A named
	encoder is used whatever this says.
	*/
	uint32_t codecs;
} yv_share_config;

typedef enum yv_share_state {
	YV_SHARE_STARTING = 1,
	YV_SHARE_LIVE = 2,
	YV_SHARE_FAILED = 3, // yv_share_error says why
	// The user said no in the system's picker: over, with nothing to
	// report.
	YV_SHARE_CANCELLED = 4,
} yv_share_state;

typedef struct yv_packet {
	const uint8_t *data; // the library's, until the next yv_share_pull or yv_share_stop
	size_t size;
	uint64_t pts_us; // when it was captured (yv_clock_us)
	yv_codec codec;
	bool key; // a keyframe, which a decoder can start from
} yv_packet;

// A share, already starting; NULL only for nonsense in `config`.
YV_API yv_share *yv_share_start(yv_context *ctx, const yv_share_config *config);
// The next encoded frame, if there is one. Any one thread.
YV_API bool yv_share_pull(yv_share *share, yv_packet *out);
// Makes the next frame a keyframe. Any thread.
YV_API void yv_share_request_key(yv_share *share);

/*
yv_share_set_bitrate changes the bitrate (kbit/s), to follow what the
network takes. A change costs a keyframe with every encoder (NVENC and
Quick Sync change as they go, the others are started again), so it's
only taken up for a change of a fifth or more (or any back to the
config's bitrate), at most every 3 seconds; asking again later is how a
smaller one gets through. Any thread.
*/
YV_API void yv_share_set_bitrate(yv_share *share, uint32_t kbit);
/*
yv_share_get_bitrate is the bitrate (kbit/s) the share encodes at now:
yv_share_set_bitrate's once it's been taken up, the config's before.
Any thread.
*/
YV_API uint32_t yv_share_get_bitrate(yv_share *share);
/*
yv_share_set_codecs says what the viewers can decode now (as
yv_share_config.codecs). Where that rules out the codec being encoded,
the share goes on with another encoder (on the same GPU where there's
one, else in software), starting with a keyframe. Any thread.
*/
YV_API void yv_share_set_codecs(yv_share *share, uint32_t codecs);
YV_API yv_share_state yv_share_get_state(yv_share *share);
// Why it failed, or "" ; valid until yv_share_stop.
YV_API const char *yv_share_error(yv_share *share);
/*
Stops the share and frees it. A camera's share that has shown its
preview (yv_share_preview) lets go of it on the client's device, so it
is stopped from the thread of yv_set_gpu, after the client has let go
of the preview's texture.
*/
YV_API void yv_share_stop(yv_share *share);

/*
Cameras (misc/video-chat/README.md): a camera is a share like a screen,
started from a camera instead of a monitor or window. Everything above
for shares holds for it too. Its pictures are converted and scaled on
the CPU, so the encoder takes them from memory.

On Windows cameras come through DirectShow, from dshowcapture.dll next
to the library (libdshowcapture, LGPL); without it there are none. That
includes virtual cameras such as OBS's, which Media Foundation doesn't
see. Linux and macOS have none yet.
*/
#define YV_CAMERA_ID_SIZE 512

typedef struct yv_camera {
	char id[YV_CAMERA_ID_SIZE]; // what to pass back: a device path, or the name of one without
	char name[YV_NAME_SIZE];    // "Logitech C920"
	// Its biggest picture, and the most frames a second it takes at that size.
	int32_t max_width, max_height, max_fps;
	bool front; // a phone's or laptop's own camera, where that's known
} yv_camera;

/*
yv_list_cameras fills `out` with up to `max` cameras and says how many
there are in all. It asks the system each time, which can take a
moment, so not from a thread that draws. They're listed even while
they aren't allowed (yv_camera_allowed); starting one then fails,
saying where to allow it.
*/
YV_API int yv_list_cameras(yv_context *ctx, yv_camera *out, int max);

/*
Whether this process may use a camera. On Windows that's the camera
switches in Settings (Privacy & security, Camera: for the whole
computer, and for desktop apps), which are only read; `ask` changes
nothing there. On macOS it's true until the user said no; `ask` shows
macOS's prompt if they haven't answered yet, and waits for the answer
(starting a camera asks too). Elsewhere always true.
*/
YV_API bool yv_camera_allowed(yv_context *ctx, bool ask);

typedef struct yv_camera_config {
	char camera[YV_CAMERA_ID_SIZE]; // yv_camera.id, or "" for the first there is
	char encoder[64];               // as yv_share_config's
	int32_t fps;                    // at most this many frames a second
	int32_t max_width, max_height;  // scaled down to fit, keeping its shape; 0 for no limit
	uint32_t kbit;
	uint32_t codecs; // as yv_share_config's
} yv_camera_config;

/*
yv_camera_start opens the camera and shares it: NULL only for nonsense
in `config`. The camera is opened at the mode that best covers the
config's size and frame rate, but at least 1280x720 where it has that,
so that yv_share_configure can go up again later without opening it
anew. A camera that another program has (and doesn't share) fails the
share, saying so (yv_share_error), as does one that's unplugged or
stops sending pictures.
*/
YV_API yv_share *yv_camera_start(yv_context *ctx, const yv_camera_config *config);

/*
yv_share_configure has a share go on at another size, frame rate and
bitrate, as yv_share_config's fields: when the number of cameras in the
room changes. It costs a keyframe. The bitrate is then also what
yv_share_set_bitrate's changes come back to. Any thread.
*/
YV_API void yv_share_configure(yv_share *share, int32_t fps, int32_t max_width, int32_t max_height,
                               uint32_t kbit);

/*
yv_share_preview is a camera's newest picture as it's encoded (not
mirrored), for the self view, as yv_view_present describes it: false
until there's one, and always for a screen. From the thread of
yv_set_gpu.
*/
YV_API bool yv_share_preview(yv_share *share, yv_picture *out);

// The clock pts_us counts on: microseconds, steady, from some point.
YV_API uint64_t yv_clock_us(void);

#ifdef __cplusplus
}
#endif

#endif
