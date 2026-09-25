/*
miniaudio, trimmed to what yap needs: listing devices and streaming raw
samples to and from them. Built into a static library by build.sh /
build.bat; the Odin bindings are in miniaudio.odin.
*/

/* No file formats, generators, or the high-level engine/node graph. */
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE

/* Only the backends we'd actually use per platform. On Linux, PulseAudio
   covers PipeWire too (through pipewire-pulse); ALSA is the fallback.
   Linux backends are loaded at runtime, so nothing extra is linked, and
   so is OpenBSD's, sndio. In a browser it's Web Audio, on
   ScriptProcessorNodes: they call back on the page's one thread, which is
   all the web build has (see web/build.sh). */
#define MA_ENABLE_ONLY_SPECIFIC_BACKENDS
#if defined(_WIN32)
    #define MA_ENABLE_WASAPI
#elif defined(__APPLE__)
    #define MA_ENABLE_COREAUDIO
#elif defined(__EMSCRIPTEN__)
    #define MA_ENABLE_WEBAUDIO
#elif defined(__OpenBSD__)
    #define MA_ENABLE_SNDIO
#else
    #define MA_ENABLE_PULSEAUDIO
    #define MA_ENABLE_ALSA
#endif

/* Everything in miniaudio becomes static: only what this file calls ends up
   in the library, and nothing can clash with another copy of miniaudio. */
#define MA_API static
#define MINIAUDIO_IMPLEMENTATION

#if defined(__GNUC__) || defined(__clang__)
    #pragma GCC diagnostic push
    #pragma GCC diagnostic ignored "-Wunused-function"
    #pragma GCC diagnostic ignored "-Wunused-variable"
#endif
#include "../../../deps/thirdparty/miniaudio/miniaudio.h"
#if defined(__GNUC__) || defined(__clang__)
    #pragma GCC diagnostic pop
#endif

#include "yap_audio.h"

#include <stdlib.h>
#include <string.h>

typedef char yap_audio_id_fits[sizeof(ma_device_id) <= YAP_AUDIO_ID_SIZE ? 1 : -1];

struct yap_audio {
    ma_context      context;
    ma_device_info* playback;
    ma_uint32       playback_count;
    ma_device_info* capture;
    ma_uint32       capture_count;
};

struct yap_audio_stream {
    ma_device          device;
    yap_audio_callback callback;
    void*              user;
};

yap_audio* yap_audio_create(int* result)
{
    yap_audio* a = (yap_audio*)calloc(1, sizeof(yap_audio));
    ma_result r;
    if (a == NULL) {
        if (result) *result = MA_OUT_OF_MEMORY;
        return NULL;
    }
    r = ma_context_init(NULL, 0, NULL, &a->context);
    if (result) *result = r;
    if (r != MA_SUCCESS) {
        free(a);
        return NULL;
    }
    return a;
}

void yap_audio_destroy(yap_audio* a)
{
    if (a == NULL) return;
    ma_context_uninit(&a->context);
    free(a);
}

const char* yap_audio_backend_name(yap_audio* a)
{
    return ma_get_backend_name(a->context.backend);
}

const char* yap_audio_result_string(int result)
{
    return ma_result_description((ma_result)result);
}

int yap_audio_refresh(yap_audio* a)
{
    /* The arrays belong to the context and stay valid until the next call. */
    ma_result r = ma_context_get_devices(&a->context, &a->playback, &a->playback_count, &a->capture, &a->capture_count);
    if (r != MA_SUCCESS) {
        a->playback = a->capture = NULL;
        a->playback_count = a->capture_count = 0;
    }
    return r;
}

static ma_device_info* device_at(yap_audio* a, yap_audio_direction dir, int index)
{
    ma_device_info* list  = dir == YAP_AUDIO_CAPTURE ? a->capture       : a->playback;
    ma_uint32       count = dir == YAP_AUDIO_CAPTURE ? a->capture_count : a->playback_count;
    return (index >= 0 && (ma_uint32)index < count) ? &list[index] : NULL;
}

int yap_audio_device_count(yap_audio* a, yap_audio_direction dir)
{
    return (int)(dir == YAP_AUDIO_CAPTURE ? a->capture_count : a->playback_count);
}

int yap_audio_device_info(yap_audio* a, yap_audio_direction dir, int index,
                          char name[YAP_AUDIO_NAME_SIZE], int* is_default, yap_audio_device_id* id)
{
    ma_device_info* info = device_at(a, dir, index);
    if (info == NULL) return MA_INVALID_ARGS;
    if (name) ma_strncpy_s(name, YAP_AUDIO_NAME_SIZE, info->name, (size_t)-1);
    if (is_default) *is_default = info->isDefault ? 1 : 0;
    if (id) {
        memset(id, 0, sizeof(*id));
        memcpy(id->bytes, &info->id, sizeof(info->id));
    }
    return MA_SUCCESS;
}

static void data_callback(ma_device* device, void* output, const void* input, ma_uint32 frame_count)
{
    yap_audio_stream* s = (yap_audio_stream*)device->pUserData;
    if (device->type == ma_device_type_capture) {
        s->callback(s->user, (float*)input, frame_count);
    } else {
        s->callback(s->user, (float*)output, frame_count);
    }
}

yap_audio_stream* yap_audio_stream_open(yap_audio* a, yap_audio_direction dir, const yap_audio_device_id* id,
                                        unsigned int sample_rate, unsigned int channels, unsigned int period_ms,
                                        yap_audio_callback callback, void* user, int* result)
{
    ma_device_config config;
    ma_device_id     device_id;
    ma_result        r;
    yap_audio_stream* s = (yap_audio_stream*)calloc(1, sizeof(yap_audio_stream));
    if (s == NULL) {
        if (result) *result = MA_OUT_OF_MEMORY;
        return NULL;
    }
    s->callback = callback;
    s->user     = user;

    if (id) memcpy(&device_id, id->bytes, sizeof(device_id));

    config = ma_device_config_init(dir == YAP_AUDIO_CAPTURE ? ma_device_type_capture : ma_device_type_playback);
    config.sampleRate         = sample_rate;
    config.periodSizeInMilliseconds = period_ms;
    config.dataCallback       = data_callback;
    config.pUserData          = s;
    /* Playback buffers start silent, so a callback that writes nothing is quiet. */
    config.noPreSilencedOutputBuffer = MA_FALSE;
    if (dir == YAP_AUDIO_CAPTURE) {
        config.capture.format   = ma_format_f32;
        config.capture.channels = channels;
        config.capture.pDeviceID = id ? &device_id : NULL;
    } else {
        config.playback.format   = ma_format_f32;
        config.playback.channels = channels;
        config.playback.pDeviceID = id ? &device_id : NULL;
    }

    r = ma_device_init(&a->context, &config, &s->device);
    if (result) *result = r;
    if (r != MA_SUCCESS) {
        free(s);
        return NULL;
    }
    return s;
}

int yap_audio_stream_start(yap_audio_stream* s)
{
    return ma_device_start(&s->device);
}

int yap_audio_stream_stop(yap_audio_stream* s)
{
    return ma_device_stop(&s->device);
}

void yap_audio_stream_close(yap_audio_stream* s)
{
    if (s == NULL) return;
    ma_device_uninit(&s->device);
    free(s);
}

unsigned int yap_audio_stream_channels(yap_audio_stream* s)
{
    return s->device.type == ma_device_type_capture ? s->device.capture.channels : s->device.playback.channels;
}

void yap_audio_stream_device_name(yap_audio_stream* s, char name[YAP_AUDIO_NAME_SIZE])
{
    ma_device_type type = s->device.type;
    if (ma_device_get_name(&s->device, type, name, YAP_AUDIO_NAME_SIZE, NULL) != MA_SUCCESS) {
        name[0] = '\0';
    }
}
