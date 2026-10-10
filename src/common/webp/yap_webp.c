/*
What src/common/webp binds: libwebp's simple decoding API as it is, its
advanced encoding API behind one call, and libwebpdemux's animation
decoder behind a handle, so that WebPConfig, WebPPicture and the
animation's structs (large, and laid out differently from one release
to the next) stay on this side.
*/
#include <stddef.h>
#include <stdint.h>

#include "webp/decode.h"
#include "webp/demux.h"
#include "webp/encode.h"

/* The size of a WebP picture, from its header; 0 if it isn't one. */
int yap_webp_info(const uint8_t *data, size_t size, int *width, int *height) {
	return WebPGetInfo(data, size, width, height);
}

/*
Decodes into `out`, which holds `out_size` bytes of RGBA rows `stride`
bytes apart. 0 if it can't (an animation, or broken data).
*/
int yap_webp_decode_rgba(const uint8_t *data, size_t size, uint8_t *out, size_t out_size, int stride) {
	return WebPDecodeRGBAInto(data, size, out, out_size, stride) != NULL;
}

/* Whether a WebP picture is an animation: 1 if it is, 0 if it's a still
one, -1 if it isn't a WebP that can be read. */
int yap_webp_is_animation(const uint8_t *data, size_t size) {
	WebPBitstreamFeatures features;
	if (WebPGetFeatures(data, size, &features) != VP8_STATUS_OK) {
		return -1;
	}
	return features.has_animation ? 1 : 0;
}

/*
Opens an animation for its frames to be decoded one after the other,
each the whole canvas as RGBA. `data` must stay as it is until it's
closed. A still picture opens too, as one frame. NULL for broken data.
*/
WebPAnimDecoder *yap_webp_anim_open(
	const uint8_t *data,
	size_t size,
	int *width,
	int *height,
	int *frames,
	int *loops
) {
	WebPAnimDecoderOptions options;
	WebPData webp_data;
	WebPAnimInfo info;
	WebPAnimDecoder *dec;

	if (!WebPAnimDecoderOptionsInit(&options)) {
		return NULL;
	}
	options.color_mode = MODE_RGBA;
	options.use_threads = 0;
	webp_data.bytes = data;
	webp_data.size = size;
	dec = WebPAnimDecoderNew(&webp_data, &options);
	if (dec == NULL) {
		return NULL;
	}
	if (!WebPAnimDecoderGetInfo(dec, &info) || info.frame_count == 0) {
		WebPAnimDecoderDelete(dec);
		return NULL;
	}
	*width = (int)info.canvas_width;
	*height = (int)info.canvas_height;
	*frames = (int)info.frame_count;
	*loops = (int)info.loop_count;
	return dec;
}

/*
Decodes the next frame: *pixels is the canvas (width * height * 4 bytes,
good until the next call), and *timestamp when it ends, in milliseconds
from the start. 1 for a frame, 0 past the last one, -1 for broken data.
*/
int yap_webp_anim_next(WebPAnimDecoder *dec, uint8_t **pixels, int *timestamp) {
	if (!WebPAnimDecoderHasMoreFrames(dec)) {
		return 0;
	}
	return WebPAnimDecoderGetNext(dec, pixels, timestamp) ? 1 : -1;
}

/* Starts again from the first frame. */
void yap_webp_anim_reset(WebPAnimDecoder *dec) {
	WebPAnimDecoderReset(dec);
}

void yap_webp_anim_close(WebPAnimDecoder *dec) {
	WebPAnimDecoderDelete(dec);
}

/*
Compresses `pixels` (rows of width * 3 bytes of RGB, or with `alpha`
width * 4 of RGBA) lossily at `quality` (0 to 100), with `method` (0,
fastest, to 6, smallest) trading speed for size; alpha is kept losslessly.
Returns the size of what's put in *out, to free with yap_webp_free, or 0
if it fails.
*/
size_t yap_webp_encode(const uint8_t *pixels, int width, int height, int alpha, float quality, int method, uint8_t **out) {
	WebPConfig config;
	WebPPicture picture;
	WebPMemoryWriter writer;
	int ok;

	*out = NULL;
	if (!WebPConfigInit(&config) || !WebPPictureInit(&picture)) {
		return 0;
	}
	config.quality = quality;
	config.method = method;
	if (!WebPValidateConfig(&config)) {
		return 0;
	}
	picture.width = width;
	picture.height = height;
	ok = alpha ? WebPPictureImportRGBA(&picture, pixels, width * 4)
	           : WebPPictureImportRGB(&picture, pixels, width * 3);
	if (!ok) {
		WebPPictureFree(&picture);
		return 0;
	}
	WebPMemoryWriterInit(&writer);
	picture.writer = WebPMemoryWrite;
	picture.custom_ptr = &writer;
	ok = WebPEncode(&config, &picture);
	WebPPictureFree(&picture);
	if (!ok) {
		WebPMemoryWriterClear(&writer);
		return 0;
	}
	*out = writer.mem;
	return writer.size;
}

void yap_webp_free(void *p) {
	WebPFree(p);
}
