/*
 * HTTP requests for the scripts (src/client/script/http_native.odin), over
 * tinyrequests (deps/thirdparty/tinyrequests): WinHTTP on Windows, CFNetwork on
 * macOS, and a libcurl found at run time elsewhere. The requests are driven by
 * polling, from the thread that steps the scripts; nothing here has a thread of
 * its own and nothing waits.
 */
#ifndef YAP_REQUESTS_H
#define YAP_REQUESTS_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct yap_http yap_http;

typedef struct yap_http_header {
    const char *name;
    const char *value;
} yap_http_header;

typedef struct yap_http_result {
    int code;                         /* 0, or a TR_ERROR_* (see tinyrequests.h) */
    long status;                      /* the HTTP status, 0 if there was none */
    const unsigned char *body;        /* NUL terminated after body_len */
    size_t body_len;
    const yap_http_header *headers;
    size_t header_count;
    char error[128];                  /* what went wrong, if code isn't 0 */
    void *priv;
} yap_http_result;

/*
 * Makes a client, or NULL if there is no way to make requests here (no libcurl
 * on Linux). `backend` gets its name ("libcurl", "winhttp", "cfnetwork") if it was
 * made. A response larger than max_response bytes stops the request.
 */
yap_http *yap_http_new(size_t max_response, const char **backend);
void yap_http_free(yap_http *h);

/*
 * Starts a request: `headers` are name and value pairs, `header_count` of them.
 * NULL (and err filled in) if it could not be started. The handle is for
 * yap_http_poll or yap_http_cancel, whichever comes first.
 */
void *yap_http_begin(yap_http *h, const char *method, const char *url, const void *body, size_t body_len,
                     const char *const *headers, int header_count, long timeout_ms, char *err, size_t errlen);

/* 0 while it goes on. 1 when it is over, with the result (give it to yap_http_result_free), and the handle is gone. */
int yap_http_poll(yap_http *h, void *handle, yap_http_result *out);

void yap_http_result_free(yap_http_result *r);

/* Gives up on a request that is still going on. */
void yap_http_cancel(yap_http *h, void *handle);

#ifdef __cplusplus
}
#endif

#endif
