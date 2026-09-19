/*
RNNoise noise suppression (ref/: the Xiph/Mozilla RNNoise that OBS
Studio's noise filter uses, BSD-3-Clause, see ref/COPYING), compiled as
one translation unit for yap. The ref/ sources are used unmodified.

Two adaptations, both done here with the preprocessor:

- Every global symbol gets a yap_ prefix. RNNoise was split off from Opus
  and shares function names with libopus (pitch_search, _celt_lpc, the
  kiss FFT, ...) but not their signatures or state layouts. Linked
  side by side, the linker would pick one library's version for both.

- COMPILE_OPUS is defined, which is what makes kiss_fft.c include its
  FFT entry points (opus_fft_c, ...). Without it, denoise.c's calls to
  them would quietly resolve to libopus's FFT instead.

The model is the built-in one (rnn_data.c); rnn_reader.c (loading models
from files) and the training code are left out.
*/

#if defined(_MSC_VER)
    #define _USE_MATH_DEFINES
#endif
#include <math.h>
#ifndef M_PI
    #define M_PI 3.14159265358979323846
#endif

#define COMPILE_OPUS

/* Internal symbols. */
#define _celt_autocorr          yap_rnn__celt_autocorr
#define celt_fir                yap_rnn_celt_fir
#define celt_iir                yap_rnn_celt_iir
#define _celt_lpc               yap_rnn__celt_lpc
#define celt_pitch_xcorr        yap_rnn_celt_pitch_xcorr
#define common                  yap_rnn_common
#define compute_band_corr       yap_rnn_compute_band_corr
#define compute_band_energy     yap_rnn_compute_band_energy
#define compute_rnn             yap_rnn_compute_rnn
#define interp_band_gain        yap_rnn_interp_band_gain
#define opus_fft_alloc          yap_rnn_opus_fft_alloc
#define opus_fft_alloc_arch_c   yap_rnn_opus_fft_alloc_arch_c
#define opus_fft_alloc_twiddles yap_rnn_opus_fft_alloc_twiddles
#define opus_fft_free           yap_rnn_opus_fft_free
#define opus_fft_free_arch_c    yap_rnn_opus_fft_free_arch_c
#define opus_fft_c              yap_rnn_opus_fft_c
#define opus_ifft_c             yap_rnn_opus_ifft_c
#define opus_fft_impl           yap_rnn_opus_fft_impl
#define opus_ifft_impl          yap_rnn_opus_ifft_impl
#define pitch_downsample        yap_rnn_pitch_downsample
#define pitch_filter            yap_rnn_pitch_filter
#define pitch_search            yap_rnn_pitch_search
#define remove_doubling         yap_rnn_remove_doubling
#define rnnoise_model_orig      yap_rnn_rnnoise_model_orig

/* The public API (see yap_rnn.h). */
#define rnnoise_get_size        yap_rnnoise_get_size
#define rnnoise_init            yap_rnnoise_init
#define rnnoise_create          yap_rnnoise_create
#define rnnoise_destroy         yap_rnnoise_destroy
#define rnnoise_process_frame   yap_rnnoise_process_frame

#if defined(__GNUC__) || defined(__clang__)
    #pragma GCC diagnostic ignored "-Wunused-function"
    #pragma GCC diagnostic ignored "-Wunused-parameter"
    #pragma GCC diagnostic ignored "-Wsign-compare"
    #pragma GCC diagnostic ignored "-Wstrict-prototypes"
#endif

#include "impl/kiss_fft.c"
#include "impl/celt_lpc.c"
#include "impl/pitch.c"
#include "impl/rnn.c"
#include "impl/rnn_data.c"
#include "impl/denoise.c"

/* denoise.c fills its FFT and window tables lazily on first use, without
   locking; call this once before using denoisers from any thread. */
void yap_rnnoise_global_init(void)
{
    check_init();
}
