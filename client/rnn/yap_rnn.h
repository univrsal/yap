/*
RNNoise as built by yap_rnn.c. Same API as ref/include/rnnoise.h, with a
yap_ prefix, and without model loading (the built-in model is used).

Frames are YAP_RNNOISE_FRAME_SIZE samples (10 ms) of 48 kHz mono audio,
as floats in 16-bit range (-32768..32767). process_frame returns the
probability (0..1) that the frame contains voice.
*/
#ifndef YAP_RNN_H
#define YAP_RNN_H

#define YAP_RNNOISE_FRAME_SIZE 480

typedef struct DenoiseState DenoiseState;

void          yap_rnnoise_global_init(void);
DenoiseState* yap_rnnoise_create(void* model /* NULL: built-in */);
void          yap_rnnoise_destroy(DenoiseState* st);
float         yap_rnnoise_process_frame(DenoiseState* st, float* out, const float* in);

#endif
