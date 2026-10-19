/*
FFmpeg, for every part of the library: include this, never FFmpeg's own
headers (except the hardware ones that only declare types, such as
hwcontext_drm.h, which may come after it).

On Windows the library links FFmpeg's DLLs. Elsewhere FFmpeg is opened
at run time (load_ffmpeg), so the library loads without it: from the
library's own folder if FFmpeg is there, as we ship it, or else the
system's. That can be FFmpeg 8 or 9: built against 8's headers, every
field and value the library uses is the same in both (FFmpeg 7's
AVFrame and AVCodecContext are laid out differently, so it isn't
taken). A new major version has to be checked the same way before it's
added to ffmpeg.cpp.

Its functions are called through a table of pointers, which the
defines at the end put in place of the names, so the code calls them
as usual. Any FFmpeg function the library calls has to be in
YV_FFMPEG_FUNCS and have its define; one that isn't would be linked
directly, which `nm -D --undefined-only` shows.
*/
#pragma once

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/buffer.h>
#include <libavutil/dict.h>
#include <libavutil/frame.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
#include <libavutil/log.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>
}

namespace yv {

/*
load_ffmpeg opens FFmpeg the first time it's called, and says whether
it could; the library's calls into FFmpeg must come after one that
said yes. ffmpeg_where says which FFmpeg that was, for the log.
*/
bool load_ffmpeg();
const char *ffmpeg_where();

// Whether FFmpeg is the one we ship, whose build we know (encoders.cpp).
bool ffmpeg_bundled();

} // namespace yv

#if !defined(_WIN32)

static_assert(LIBAVCODEC_VERSION_MAJOR == 62 || LIBAVCODEC_VERSION_MAJOR == 63,
              "FFmpeg 8 or 9's headers, which are what ffmpeg.cpp opens");

#define YV_FFMPEG_FUNCS(X)                                                                        \
	X(av_buffer_create)                                                                            \
	X(av_buffer_default_free)                                                                      \
	X(av_buffer_ref)                                                                               \
	X(av_buffer_unref)                                                                             \
	X(av_dict_free)                                                                                \
	X(av_dict_set)                                                                                 \
	X(av_dict_set_int)                                                                             \
	X(av_frame_alloc)                                                                              \
	X(av_frame_clone)                                                                              \
	X(av_frame_copy_props)                                                                         \
	X(av_frame_free)                                                                               \
	X(av_frame_get_buffer)                                                                         \
	X(av_frame_make_writable)                                                                      \
	X(av_frame_unref)                                                                              \
	X(av_hwdevice_ctx_create)                                                                      \
	X(av_hwdevice_get_type_name)                                                                   \
	X(av_hwframe_ctx_alloc)                                                                        \
	X(av_hwframe_ctx_init)                                                                         \
	X(av_hwframe_get_buffer)                                                                       \
	X(av_hwframe_map)                                                                              \
	X(av_hwframe_transfer_data)                                                                    \
	X(av_log_format_line)                                                                          \
	X(av_log_set_callback)                                                                         \
	X(av_mallocz)                                                                                  \
	X(av_pix_fmt_desc_get)                                                                         \
	X(av_strerror)                                                                                 \
	X(avutil_version)                                                                              \
	X(av_packet_alloc)                                                                             \
	X(av_packet_free)                                                                              \
	X(av_packet_unref)                                                                             \
	X(avcodec_alloc_context3)                                                                      \
	X(avcodec_find_decoder_by_name)                                                                \
	X(avcodec_find_encoder_by_name)                                                                \
	X(avcodec_free_context)                                                                        \
	X(avcodec_get_hw_config)                                                                       \
	X(avcodec_get_supported_config)                                                                \
	X(avcodec_is_open)                                                                             \
	X(avcodec_open2)                                                                               \
	X(avcodec_receive_frame)                                                                       \
	X(avcodec_receive_packet)                                                                      \
	X(avcodec_send_frame)                                                                          \
	X(avcodec_send_packet)                                                                         \
	X(avcodec_version)                                                                             \
	X(sws_freeContext)                                                                             \
	X(sws_getCachedContext)                                                                        \
	X(sws_getCoefficients)                                                                         \
	X(sws_scale)                                                                                   \
	X(sws_setColorspaceDetails)                                                                    \
	X(swscale_version)

namespace yv {

#define YV_FFMPEG_POINTER(f) decltype(&::f) f = nullptr;
struct Ffmpeg {
	YV_FFMPEG_FUNCS(YV_FFMPEG_POINTER)
};
#undef YV_FFMPEG_POINTER

extern Ffmpeg ff;

} // namespace yv

// ffmpeg.cpp fills the table in by these names, so it goes without.
#if !defined(YV_FFMPEG_TABLE_ONLY)
#define av_buffer_create ::yv::ff.av_buffer_create
#define av_buffer_default_free ::yv::ff.av_buffer_default_free
#define av_buffer_ref ::yv::ff.av_buffer_ref
#define av_buffer_unref ::yv::ff.av_buffer_unref
#define av_dict_free ::yv::ff.av_dict_free
#define av_dict_set ::yv::ff.av_dict_set
#define av_dict_set_int ::yv::ff.av_dict_set_int
#define av_frame_alloc ::yv::ff.av_frame_alloc
#define av_frame_clone ::yv::ff.av_frame_clone
#define av_frame_copy_props ::yv::ff.av_frame_copy_props
#define av_frame_free ::yv::ff.av_frame_free
#define av_frame_get_buffer ::yv::ff.av_frame_get_buffer
#define av_frame_make_writable ::yv::ff.av_frame_make_writable
#define av_frame_unref ::yv::ff.av_frame_unref
#define av_hwdevice_ctx_create ::yv::ff.av_hwdevice_ctx_create
#define av_hwdevice_get_type_name ::yv::ff.av_hwdevice_get_type_name
#define av_hwframe_ctx_alloc ::yv::ff.av_hwframe_ctx_alloc
#define av_hwframe_ctx_init ::yv::ff.av_hwframe_ctx_init
#define av_hwframe_get_buffer ::yv::ff.av_hwframe_get_buffer
#define av_hwframe_map ::yv::ff.av_hwframe_map
#define av_hwframe_transfer_data ::yv::ff.av_hwframe_transfer_data
#define av_log_format_line ::yv::ff.av_log_format_line
#define av_log_set_callback ::yv::ff.av_log_set_callback
#define av_mallocz ::yv::ff.av_mallocz
#define av_pix_fmt_desc_get ::yv::ff.av_pix_fmt_desc_get
#define av_strerror ::yv::ff.av_strerror
#define avutil_version ::yv::ff.avutil_version
#define av_packet_alloc ::yv::ff.av_packet_alloc
#define av_packet_free ::yv::ff.av_packet_free
#define av_packet_unref ::yv::ff.av_packet_unref
#define avcodec_alloc_context3 ::yv::ff.avcodec_alloc_context3
#define avcodec_find_decoder_by_name ::yv::ff.avcodec_find_decoder_by_name
#define avcodec_find_encoder_by_name ::yv::ff.avcodec_find_encoder_by_name
#define avcodec_free_context ::yv::ff.avcodec_free_context
#define avcodec_get_hw_config ::yv::ff.avcodec_get_hw_config
#define avcodec_get_supported_config ::yv::ff.avcodec_get_supported_config
#define avcodec_is_open ::yv::ff.avcodec_is_open
#define avcodec_open2 ::yv::ff.avcodec_open2
#define avcodec_receive_frame ::yv::ff.avcodec_receive_frame
#define avcodec_receive_packet ::yv::ff.avcodec_receive_packet
#define avcodec_send_frame ::yv::ff.avcodec_send_frame
#define avcodec_send_packet ::yv::ff.avcodec_send_packet
#define avcodec_version ::yv::ff.avcodec_version
#define sws_freeContext ::yv::ff.sws_freeContext
#define sws_getCachedContext ::yv::ff.sws_getCachedContext
#define sws_getCoefficients ::yv::ff.sws_getCoefficients
#define sws_scale ::yv::ff.sws_scale
#define sws_setColorspaceDetails ::yv::ff.sws_setColorspaceDetails
#define swscale_version ::yv::ff.swscale_version
#endif

#endif
