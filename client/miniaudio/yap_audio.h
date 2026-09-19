/*
A small C API over a trimmed-down miniaudio (see yap_audio.c), so the Odin
side never has to mirror miniaudio's large structs, whose layout depends
on the compile-time configuration.

Everything is opaque handles and plain values. Audio data is always
interleaved 32-bit float at the rate and channel count asked for;
miniaudio converts from/to whatever the device actually uses.
*/
#ifndef YAP_AUDIO_H
#define YAP_AUDIO_H

#ifdef __cplusplus
extern "C" {
#endif

#define YAP_AUDIO_NAME_SIZE 256
/* Opaque device id; at least sizeof(ma_device_id) (checked in yap_audio.c). */
#define YAP_AUDIO_ID_SIZE   512

typedef struct yap_audio        yap_audio;
typedef struct yap_audio_stream yap_audio_stream;

typedef struct {
    unsigned char bytes[YAP_AUDIO_ID_SIZE];
} yap_audio_device_id;

typedef enum {
    YAP_AUDIO_PLAYBACK = 0,
    YAP_AUDIO_CAPTURE  = 1
} yap_audio_direction;

/* Results are miniaudio's ma_result values: 0 is success, negative is an error. */

/* Context: picks the platform's audio backend. NULL if none works. */
yap_audio*  yap_audio_create(int* result);
void        yap_audio_destroy(yap_audio* a);
const char* yap_audio_backend_name(yap_audio* a);
const char* yap_audio_result_string(int result);

/* Device listing. yap_audio_refresh re-enumerates; the count and info
   calls read the list from the last refresh. */
int yap_audio_refresh(yap_audio* a);
int yap_audio_device_count(yap_audio* a, yap_audio_direction dir);
int yap_audio_device_info(yap_audio* a, yap_audio_direction dir, int index,
                          char name[YAP_AUDIO_NAME_SIZE], int* is_default, yap_audio_device_id* id);

/*
Streams. The callback runs on miniaudio's audio thread, once per period:
for capture, `samples` holds `frame_count` frames that were recorded; for
playback, fill `samples` with `frame_count` frames (it starts zeroed).
It must not block.

`id` NULL means the system default device. `channels` 0 means the device's
native channel count, with no channel conversion by miniaudio.
*/
typedef void (*yap_audio_callback)(void* user, float* samples, unsigned int frame_count);

yap_audio_stream* yap_audio_stream_open(yap_audio* a, yap_audio_direction dir, const yap_audio_device_id* id,
                                        unsigned int sample_rate, unsigned int channels, unsigned int period_ms,
                                        yap_audio_callback callback, void* user, int* result);
int  yap_audio_stream_start(yap_audio_stream* s);
int  yap_audio_stream_stop(yap_audio_stream* s);
void yap_audio_stream_close(yap_audio_stream* s);
/* The channel count the stream delivers/expects: what was asked for, or the
   device's native count if 0 was passed to yap_audio_stream_open. */
unsigned int yap_audio_stream_channels(yap_audio_stream* s);
/* Name of the device actually opened (useful when the default was asked for). */
void yap_audio_stream_device_name(yap_audio_stream* s, char name[YAP_AUDIO_NAME_SIZE]);

#ifdef __cplusplus
}
#endif
#endif
