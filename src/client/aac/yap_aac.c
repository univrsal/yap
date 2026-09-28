/*
tinyaac (tinyaac.h, public domain or MIT), per-application audio
capture, compiled as one translation unit for yap. The header is used
unmodified; this file is only here to hold its implementation and the
one thing yap adds, yap_aac_init.

On Linux tinyaac talks to PipeWire, which it would normally link
directly. Here libpipewire-0.3 is loaded with dlopen() instead (the
same approach as traycon_dl.h for the tray), so yap-client still starts
on a desktop without PipeWire and only application audio is missing.
The pipewire headers are included first, and every pw_ function
tinyaac.h calls is then #defined to go through a pointer filled in with
dlsym(); the pointer's type comes from the real declaration with
__typeof__, so it can't drift from what libpipewire exports. The pw_
names that aren't in this list (pw_core_sync, pw_registry_bind and so
on) are macros or inline functions in the headers, which call through
the objects' own method tables rather than a libpipewire symbol.

On Windows it's WASAPI process loopback (Windows 10 build 19041 and
later). tinyaac.h uses a few COM interface and format GUIDs that no
import library we link defines, so they're defined at the end of this
file, with the values miniaudio uses for the same ones.

On macOS it's a Core Audio process tap (macOS 14.2 and later), which is
why this is built as Objective-C there, with ARC as tinyaac.h asks. Its
macOS part names AppKit's NSRunningApplication, pthreads and the tap API
(AudioHardwareTapping.h, CATapDescription.h) without importing them,
so they're imported here first.

Anywhere else tinyaac compiles to a backend that reports itself
unavailable.
*/
#if defined(__linux__)
#define _GNU_SOURCE 1

#include <dlfcn.h>
#include <pipewire/pipewire.h>

#define YAP_PW_SYMS(X) \
	X(pw_init) \
	X(pw_deinit) \
	X(pw_thread_loop_new) \
	X(pw_thread_loop_get_loop) \
	X(pw_thread_loop_start) \
	X(pw_thread_loop_stop) \
	X(pw_thread_loop_destroy) \
	X(pw_thread_loop_lock) \
	X(pw_thread_loop_unlock) \
	X(pw_thread_loop_wait) \
	X(pw_thread_loop_signal) \
	X(pw_context_new) \
	X(pw_context_connect) \
	X(pw_context_destroy) \
	X(pw_core_disconnect) \
	X(pw_proxy_destroy) \
	X(pw_properties_new) \
	X(pw_stream_new) \
	X(pw_stream_add_listener) \
	X(pw_stream_connect) \
	X(pw_stream_disconnect) \
	X(pw_stream_destroy) \
	X(pw_stream_dequeue_buffer) \
	X(pw_stream_queue_buffer) \
	X(pw_stream_get_nsec)

#define YAP_PW_POINTER(name) static __typeof__(name) *yap_dl_##name;
YAP_PW_SYMS(YAP_PW_POINTER)
#undef YAP_PW_POINTER

/* 1 once everything is loaded, -1 if something wasn't there. */
static int yap_pw_state;

static int yap_pw_load(void)
{
	void *lib;
	if (yap_pw_state)
		return yap_pw_state > 0;
	yap_pw_state = -1;
	lib = dlopen("libpipewire-0.3.so.0", RTLD_NOW | RTLD_LOCAL);
	if (!lib)
		return 0;
#define YAP_PW_LOAD(name) \
	if (!(*(void **)&yap_dl_##name = dlsym(lib, #name))) { \
		dlclose(lib); \
		return 0; \
	}
	YAP_PW_SYMS(YAP_PW_LOAD)
#undef YAP_PW_LOAD
	/* Kept loaded for the rest of the run, like the tray's libraries. */
	yap_pw_state = 1;
	return 1;
}

#define pw_init (*yap_dl_pw_init)
#define pw_deinit (*yap_dl_pw_deinit)
#define pw_thread_loop_new (*yap_dl_pw_thread_loop_new)
#define pw_thread_loop_get_loop (*yap_dl_pw_thread_loop_get_loop)
#define pw_thread_loop_start (*yap_dl_pw_thread_loop_start)
#define pw_thread_loop_stop (*yap_dl_pw_thread_loop_stop)
#define pw_thread_loop_destroy (*yap_dl_pw_thread_loop_destroy)
#define pw_thread_loop_lock (*yap_dl_pw_thread_loop_lock)
#define pw_thread_loop_unlock (*yap_dl_pw_thread_loop_unlock)
#define pw_thread_loop_wait (*yap_dl_pw_thread_loop_wait)
#define pw_thread_loop_signal (*yap_dl_pw_thread_loop_signal)
#define pw_context_new (*yap_dl_pw_context_new)
#define pw_context_connect (*yap_dl_pw_context_connect)
#define pw_context_destroy (*yap_dl_pw_context_destroy)
#define pw_core_disconnect (*yap_dl_pw_core_disconnect)
#define pw_proxy_destroy (*yap_dl_pw_proxy_destroy)
#define pw_properties_new (*yap_dl_pw_properties_new)
#define pw_stream_new (*yap_dl_pw_stream_new)
#define pw_stream_add_listener (*yap_dl_pw_stream_add_listener)
#define pw_stream_connect (*yap_dl_pw_stream_connect)
#define pw_stream_disconnect (*yap_dl_pw_stream_disconnect)
#define pw_stream_destroy (*yap_dl_pw_stream_destroy)
#define pw_stream_dequeue_buffer (*yap_dl_pw_stream_dequeue_buffer)
#define pw_stream_queue_buffer (*yap_dl_pw_stream_queue_buffer)
#define pw_stream_get_nsec (*yap_dl_pw_stream_get_nsec)
#endif

#if defined(__APPLE__)
#include <pthread.h>
#import <AppKit/AppKit.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#endif

#define TINYAAC_IMPLEMENTATION
#include "../../../deps/thirdparty/tinyaac/tinyaac.h"

/* tinyaac_init, after making sure there's a backend library to call:
 * TINYAAC_ERR_PLATFORM_UNAVAILABLE where libpipewire couldn't be loaded. */
tinyaac_status yap_aac_init(void)
{
#if defined(__linux__)
	if (!yap_pw_load())
		return TINYAAC_ERR_PLATFORM_UNAVAILABLE;
#endif
	return tinyaac_init();
}

#if defined(_WIN32)
const IID IID_IAudioClient = {0x1CB9AD4C, 0xDBFA, 0x4C32, {0xB1, 0x78, 0xC2, 0xF5, 0x68, 0xA7, 0x03, 0xB2}};
const IID IID_IAudioCaptureClient = {0xC8ADBD64, 0xE71E, 0x48A0, {0xA4, 0xDE, 0x18, 0x5C, 0x39, 0x5C, 0xD3, 0x17}};
const IID IID_IActivateAudioInterfaceCompletionHandler = {0x41D949AB, 0x9862, 0x444A, {0x80, 0xF6, 0xC2, 0x61, 0x33, 0x4D, 0xA5, 0xEB}};
const GUID KSDATAFORMAT_SUBTYPE_PCM = {0x00000001, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}};
const GUID KSDATAFORMAT_SUBTYPE_IEEE_FLOAT = {0x00000003, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}};
#endif
