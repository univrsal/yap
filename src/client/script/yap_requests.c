/*
 * See yap_requests.h. build.sh and build.bat compile this against
 * deps/thirdparty/tinyrequests.
 */
#define TINYREQUESTS_IMPLEMENTATION
#include "tinyrequests.h"

#include <stdlib.h>
#include <string.h>
#ifndef _WIN32
#include <time.h>
#endif

#include "yap_requests.h"

/*
 * A request is a tinyrequests handle and the time by which it has to be over. The
 * library has timeouts of its own, but they are not the same in all three backends
 * (WinHTTP does not apply its timeout to this kind of request), so this one is the
 * same everywhere: it is set a little after the library's, which normally gets there
 * first and says why.
 */
typedef struct yap_req {
    tr_async *async;
    unsigned long long deadline; /* now_ms() time; 0 for none */
} yap_req;

#define DEADLINE_GRACE_MS 1000

static unsigned long long now_ms(void) {
#ifdef _WIN32
    return (unsigned long long)GetTickCount64();
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (unsigned long long)ts.tv_sec * 1000ULL + (unsigned long long)ts.tv_nsec / 1000000ULL;
#endif
}

struct yap_http {
    tr_client *client;
};

yap_http *yap_http_new(size_t max_response, const char **backend) {
    tr_config config;
    yap_http *h;
    memset(&config, 0, sizeof config);
    config.max_response_size = max_response;
    h = (yap_http *)calloc(1, sizeof *h);
    if (!h) return NULL;
    h->client = tr_client_create(&config);
    if (!h->client) {
        free(h);
        return NULL;
    }
    if (backend) *backend = tr_client_backend_name(h->client);
    return h;
}

void yap_http_free(yap_http *h) {
    if (!h) return;
    tr_client_destroy(h->client);
    free(h);
}

void *yap_http_begin(yap_http *h, const char *method, const char *url, const void *body, size_t body_len,
                     const char *const *headers, int header_count, long timeout_ms, char *err, size_t errlen) {
    tr_request request;
    tr_header *list = NULL;
    tr_async *async = NULL;
    yap_req *req;
    int i, rc;
    memset(&request, 0, sizeof request);
    if (header_count > 0) {
        list = (tr_header *)calloc((size_t)header_count, sizeof *list);
        if (!list) {
            if (errlen) strncpy(err, "out of memory", errlen - 1);
            return NULL;
        }
        for (i = 0; i < header_count; i++) {
            list[i].name = headers[2 * i];
            list[i].value = headers[2 * i + 1];
        }
    }
    request.method = method;
    request.url = url;
    request.headers = list;
    request.header_count = (size_t)header_count;
    request.body = body;
    request.body_size = body_len;
    request.timeout_ms = timeout_ms;
    rc = tr_request_begin(h->client, &request, &async);
    free(list); /* the library has copied what it needs */
    if (rc != TR_OK) {
        if (errlen) {
            strncpy(err, rc == TR_ERROR_URL ? "the address is not valid" : "the request could not be started", errlen - 1);
            err[errlen - 1] = 0;
        }
        return NULL;
    }
    req = (yap_req *)calloc(1, sizeof *req);
    if (!req) {
        tr_async_destroy(async);
        if (errlen) strncpy(err, "out of memory", errlen - 1);
        return NULL;
    }
    req->async = async;
    if (timeout_ms > 0) req->deadline = now_ms() + (unsigned long long)timeout_ms + DEADLINE_GRACE_MS;
    return req;
}

int yap_http_poll(yap_http *h, void *handle, yap_http_result *out) {
    yap_req *req = (yap_req *)handle;
    tr_response *response;
    int rc;
    tr_client_poll(h->client);
    response = (tr_response *)calloc(1, sizeof *response);
    if (!response) return 0;
    rc = tr_async_poll(h->client, req->async, response);
    if (rc == TR_IN_PROGRESS) {
        free(response);
        if (req->deadline && now_ms() > req->deadline) {
            /* Over time, whatever the library thinks: give up on it. */
            tr_async_destroy(req->async);
            free(req);
            memset(out, 0, sizeof *out);
            out->code = TR_ERROR_TIMEOUT;
            strncpy(out->error, "timeout", sizeof out->error - 1);
            return 1;
        }
        return 0;
    }
    memset(out, 0, sizeof *out);
    out->code = rc;
    out->status = response->status_code;
    out->body = response->body;
    out->body_len = response->body_size;
    out->headers = (const yap_http_header *)response->headers; /* the same two pointers */
    out->header_count = response->header_count;
    strncpy(out->error, response->error, sizeof out->error - 1);
    out->priv = response;
    tr_async_destroy(req->async);
    free(req);
    return 1;
}

void yap_http_result_free(yap_http_result *r) {
    if (r && r->priv) {
        tr_response_cleanup((tr_response *)r->priv);
        free(r->priv);
        r->priv = NULL;
    }
}

void yap_http_cancel(yap_http *h, void *handle) {
    yap_req *req = (yap_req *)handle;
    (void)h;
    if (req) {
        tr_async_destroy(req->async);
        free(req);
    }
}
