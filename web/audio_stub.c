/*
Stand-ins for the codec libraries in the web build, until voice is sent
from the browser: libopus isn't built for wasm yet. Everything here
reports "no codec", which the voice pipeline copes with - the devices
work (the level meter, the gate, listen back), but nothing is encoded or
decoded, so nothing is sent or played from anyone else. The devices
themselves are real: client/miniaudio/yap_audio.c is compiled with
miniaudio's Web Audio backend (see web/build.sh).

RNNoise is plain C and will compile for the browser as it is, but only
once its header travels with it: the desktop build finds rnnoise.h in
the system's include path. Until then it's stood in for here as well,
and noise suppression is off.
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
