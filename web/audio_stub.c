/*
Stand-ins for the audio libraries in the web build, until voice comes
to the browser: libopus isn't built for wasm yet, and miniaudio's
WebAudio backend needs the page to ask for the microphone and to run
audio on a worklet. Everything here reports "no audio", which the
client already copes with - it's what a machine without a sound card
looks like - so text chat works and voice quietly doesn't.

RNNoise is plain C and will compile for the browser as it is, but only
once its header travels with it: the desktop build finds rnnoise.h in
the system's include path. With no voice to denoise yet, it's stood in
for here as well.
*/
#include <stddef.h>

/* ---- libopus: no encoder or decoder can be made ---- */

#define OPUS_UNIMPLEMENTED (-5)

const char *opus_get_version_string(void) { return "none (web build)"; }
const char *opus_strerror(int error) { return "not available in the web build"; }

void *opus_encoder_create(int fs, int channels, int application, int *error) {
	if (error) *error = OPUS_UNIMPLEMENTED;
	return NULL;
}
void opus_encoder_destroy(void *st) {}
int opus_encoder_ctl(void *st, int request, ...) { return OPUS_UNIMPLEMENTED; }
int opus_encode_float(void *st, const float *pcm, int frame_size, unsigned char *data, int max_data_bytes) {
	return OPUS_UNIMPLEMENTED;
}

void *opus_decoder_create(int fs, int channels, int *error) {
	if (error) *error = OPUS_UNIMPLEMENTED;
	return NULL;
}
void opus_decoder_destroy(void *st) {}
int opus_decoder_ctl(void *st, int request, ...) { return OPUS_UNIMPLEMENTED; }
int opus_decode_float(void *st, const unsigned char *data, int len, float *pcm, int frame_size, int decode_fec) {
	return OPUS_UNIMPLEMENTED;
}
int opus_packet_has_lbrr(const unsigned char *packet, int len) { return 0; }

/* ---- RNNoise: no denoiser can be made ---- */

void yap_rnnoise_global_init(void) {}
void *yap_rnnoise_create(void *model) { return NULL; }
void yap_rnnoise_destroy(void *st) {}
float yap_rnnoise_process_frame(void *st, float *out, const float *in) { return 0; }

/* ---- yap_audio (miniaudio): there are no devices ---- */

typedef struct yap_audio yap_audio;
typedef struct yap_audio_stream yap_audio_stream;

#define YAP_AUDIO_NO_BACKEND (-100)

yap_audio *yap_audio_create(int *result) {
	if (result) *result = YAP_AUDIO_NO_BACKEND;
	return NULL;
}
void yap_audio_destroy(yap_audio *a) {}
const char *yap_audio_backend_name(yap_audio *a) { return "none (web build)"; }
const char *yap_audio_result_string(int result) { return "no audio in the web build yet"; }
int yap_audio_refresh(yap_audio *a) { return YAP_AUDIO_NO_BACKEND; }
int yap_audio_device_count(yap_audio *a, int dir) { return 0; }
int yap_audio_device_info(yap_audio *a, int dir, int index, char *name, int *is_default, void *id) {
	return YAP_AUDIO_NO_BACKEND;
}
yap_audio_stream *yap_audio_stream_open(yap_audio *a, int dir, const void *id, unsigned sample_rate,
                                        unsigned channels, unsigned period_ms, void *callback, void *user,
                                        int *result) {
	if (result) *result = YAP_AUDIO_NO_BACKEND;
	return NULL;
}
int yap_audio_stream_start(yap_audio_stream *s) { return YAP_AUDIO_NO_BACKEND; }
int yap_audio_stream_stop(yap_audio_stream *s) { return YAP_AUDIO_NO_BACKEND; }
void yap_audio_stream_close(yap_audio_stream *s) {}
unsigned yap_audio_stream_channels(yap_audio_stream *s) { return 0; }
void yap_audio_stream_device_name(yap_audio_stream *s, char *name) {
	if (name) name[0] = 0;
}
