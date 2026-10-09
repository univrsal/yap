/*
What src/client/webp binds: libwebp's simple decoding API as it is, and
its advanced encoding API behind one call, so that WebPConfig and
WebPPicture (large, and laid out differently from one release to the
next) stay on this side.
*/
#include <stddef.h>
#include <stdint.h>

#include "webp/decode.h"
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

/*
Compresses `rgb` (rows of width * 3 bytes) lossily at `quality` (0 to
100), with `method` (0, fastest, to 6, smallest) trading speed for size.
Returns the size of what's put in *out, to free with yap_webp_free, or 0
if it fails.
*/
size_t yap_webp_encode_rgb(const uint8_t *rgb, int width, int height, float quality, int method, uint8_t **out) {
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
	if (!WebPPictureImportRGB(&picture, rgb, width * 3)) {
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
