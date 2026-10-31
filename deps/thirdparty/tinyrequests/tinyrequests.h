/*
 * tinyrequests.h - Single-header C HTTP(S) request library
 *
 * ALTERED by the yap project (this is not the original; see the license, term 2).
 * What was changed, and nothing else:
 *   - tr_config.max_response_size: a response bigger than this (0: no limit) stops
 *     the transfer as if memory had run out (TR_ERROR_NOMEM), instead of being
 *     collected whole (tr__append_bytes).
 *   - libcurl backend: only http and https, also after a redirect, and at most 5
 *     redirects (CURLOPT_PROTOCOLS, CURLOPT_REDIR_PROTOCOLS, CURLOPT_MAXREDIRS).
 *
 * Features:
 *   - Synchronous HTTP(S) requests
 *   - Poll-driven async HTTP(S) requests with no library-managed threads
 *   - Native WinHTTP backend on Windows
 *   - Native CFNetwork/CoreFoundation backend on macOS
 *   - Runtime-loaded libcurl backend on Linux and BSD
 *   - Custom allocator hooks
 *   - Owned response body and response headers
 *
 * LICENSE
 * -------
 * This software is provided 'as-is', without any express or implied
 * warranty. In no event will the authors be held liable for any damages
 * arising from the use of this software.
 *
 * Permission is granted to anyone to use this software for any purpose,
 * including commercial applications, and to alter it and redistribute it
 * freely, subject to the following restrictions:
 *
 * 1. The origin of this software must not be misrepresented; you must not
 *    claim that you wrote the original software. If you use this software
 *    in a product, an acknowledgment in the product documentation would be
 *    appreciated but is not required.
 * 2. Altered source versions must be plainly marked as such, and must not be
 *    misrepresented as being the original software.
 * 3. This notice may not be removed or altered from any source distribution.
 *
 * USAGE:
 * ------
 *   In one C or C++ file define TINYREQUESTS_IMPLEMENTATION before including:
 *
 *     #define TINYREQUESTS_IMPLEMENTATION
 *     #include "tinyrequests.h"
 *
 *   In all other files, just include normally:
 *
 *     #include "tinyrequests.h"
 *
 * API OVERVIEW:
 *
 *   typedef struct tr_header       tr_header;
 *   typedef struct tr_owned_header tr_owned_header;
 *   typedef struct tr_request      tr_request;
 *   typedef struct tr_response     tr_response;
 *   typedef struct tr_config       tr_config;
 *   typedef struct tr_client       tr_client;
 *   typedef struct tr_async        tr_async;
 *
 *   tr_client *tr_client_create(const tr_config *config);
 *   void       tr_client_destroy(tr_client *client);
 *   const char *tr_client_backend_name(const tr_client *client);
 *
 *   int        tr_request_perform(tr_client *client, const tr_request *request, tr_response *response);
 *   int        tr_request_begin(tr_client *client, const tr_request *request, tr_async **out_async);
 *   size_t     tr_client_poll(tr_client *client);
 *   int        tr_async_poll(tr_client *client, tr_async *async_request, tr_response *out_response);
 *   int        tr_async_status(const tr_async *async_request);
 *   int        tr_async_take_response(tr_async *async_request, tr_response *out_response);
 *   void       tr_async_destroy(tr_async *async_request);
 *
 *   void       tr_response_cleanup(tr_response *response);
 *
 * ERRORS:
 *   Functions return TR_OK on success, TR_IN_PROGRESS for unfinished async
 *   operations, or a negative TR_ERROR_* code on failure. Timeouts are
 *   reported as TR_ERROR_TIMEOUT. Backend error strings are written into
 *   tr_response.error when a response object is available.
 */
#ifndef TINYREQUESTS_H
#define TINYREQUESTS_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TR_OK 0
#define TR_IN_PROGRESS 1
#define TR_ERROR_INVALID_ARGUMENT -1
#define TR_ERROR_NOMEM -2
#define TR_ERROR_BACKEND -3
#define TR_ERROR_URL -4
#define TR_ERROR_UNSUPPORTED -5
#define TR_ERROR_STATE -6
#define TR_ERROR_TIMEOUT -7

typedef void *(*tr_alloc_fn)(size_t size, void *user);
typedef void (*tr_free_fn)(void *ptr, void *user);

typedef struct tr_header {
    const char *name;
    const char *value;
} tr_header;

typedef struct tr_owned_header {
    char *name;
    char *value;
} tr_owned_header;

typedef struct tr_request {
    const char *method;
    const char *url;
    const tr_header *headers;
    size_t header_count;
    const void *body;
    size_t body_size;
    long timeout_ms;
} tr_request;

typedef struct tr_response {
    long status_code;
    unsigned char *body;
    size_t body_size;
    tr_owned_header *headers;
    size_t header_count;
    int result_code;
    char error[128];
    tr_free_fn _free_fn;
    void *_free_user;
} tr_response;

typedef struct tr_curl_slist {
    char *data;
    struct tr_curl_slist *next;
} tr_curl_slist;

typedef struct tr_curl_msg {
    int msg;
    void *easy_handle;
    union {
        void *whatever;
        int result;
    } data;
} tr_curl_msg;

typedef struct tr_curl_vtable {
    void *(*easy_init)(void);
    int (*easy_setopt)(void *easy, int option, ...);
    int (*easy_perform)(void *easy);
    void (*easy_cleanup)(void *easy);
    int (*easy_getinfo)(void *easy, int info, ...);
    const char *(*easy_strerror)(int code);
    void *(*multi_init)(void);
    int (*multi_add_handle)(void *multi, void *easy);
    int (*multi_remove_handle)(void *multi, void *easy);
    int (*multi_perform)(void *multi, int *running_handles);
    tr_curl_msg *(*multi_info_read)(void *multi, int *msgs_in_queue);
    int (*multi_cleanup)(void *multi);
    tr_curl_slist *(*slist_append)(tr_curl_slist *list, const char *string);
    void (*slist_free_all)(tr_curl_slist *list);
} tr_curl_vtable;

typedef struct tr_config {
    tr_alloc_fn alloc_fn;
    tr_free_fn free_fn;
    void *allocator_user;
    const char *curl_library_path;
    void *curl_library_handle;
    const tr_curl_vtable *curl_vtable;
    size_t max_response_size; /* yap: 0 for no limit */
} tr_config;

typedef struct tr_client tr_client;
typedef struct tr_async tr_async;

tr_client *tr_client_create(const tr_config *config);
void tr_client_destroy(tr_client *client);

const char *tr_client_backend_name(const tr_client *client);

int tr_request_perform(tr_client *client, const tr_request *request, tr_response *response);

int tr_request_begin(tr_client *client, const tr_request *request, tr_async **out_async);
size_t tr_client_poll(tr_client *client);
int tr_async_poll(tr_client *client, tr_async *async_request, tr_response *out_response);
int tr_async_status(const tr_async *async_request);
int tr_async_take_response(tr_async *async_request, tr_response *out_response);
void tr_async_destroy(tr_async *async_request);

void tr_response_cleanup(tr_response *response);

#ifdef TINYREQUESTS_IMPLEMENTATION

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <winhttp.h>
#ifdef _MSC_VER
#pragma comment(lib, "winhttp.lib")
#endif
#elif defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#include <CFNetwork/CFNetwork.h>
#else
#include <dlfcn.h>
#endif

struct tr_client {
    tr_alloc_fn alloc_fn;
    tr_free_fn free_fn;
    void *allocator_user;
    size_t max_response_size; /* yap */
    const char *backend_name;
    int backend_kind;
    tr_async *async_head;
#if !defined(_WIN32) && !defined(__APPLE__)
    int owns_curl_handle;
    void *curl_library_handle;
    tr_curl_vtable curl;
    void *curl_multi;
#endif
};

struct tr_async {
    tr_client *client;
    int status;
    int result_code;
    tr_response response;
    tr_async *next;
#if !defined(_WIN32) && !defined(__APPLE__)
    void *easy;
    tr_curl_slist *headers;
    char *method_copy;
    char *url_copy;
    unsigned char *body_copy;
    size_t body_size;
    int added_to_multi;
    int finished;
#elif defined(__APPLE__)
    CFReadStreamRef stream;
    CFHTTPMessageRef request_message;
    CFURLRef url_ref;
    CFRunLoopRef run_loop;
    char *method_copy;
    char *url_copy;
    unsigned char *body_copy;
    size_t body_size;
    int scheduled;
    int opened;
    int have_status_code;
    int stop_called;
    CFAbsoluteTime deadline;
    int has_deadline;
#else
    HINTERNET session;
    HINTERNET connection;
    HINTERNET request_handle;
    char *method_copy;
    char *url_copy;
    unsigned char *body_copy;
    size_t body_size;
    HANDLE close_event;
    CRITICAL_SECTION lock;
    int lock_ready;
    volatile LONG close_started;
    volatile LONG handle_closed;
#endif
};

static void *tr__default_alloc(size_t size, void *user) {
    (void) user;
    return malloc(size);
}

static void tr__default_free(void *ptr, void *user) {
    (void) user;
    free(ptr);
}

static void tr__response_reset(tr_response *response) {
    if (!response) {
        return;
    }
    response->status_code = 0;
    response->body = NULL;
    response->body_size = 0;
    response->headers = NULL;
    response->header_count = 0;
    response->result_code = 0;
    response->error[0] = '\0';
    response->_free_fn = NULL;
    response->_free_user = NULL;
}

static void tr__set_error(tr_response *response, int code, const char *message) {
    if (!response) {
        return;
    }
    response->result_code = code;
    if (message && message[0]) {
        snprintf(response->error, sizeof(response->error), "%s", message);
    }
}

static void tr__set_backend_error(tr_response *response, const char *backend, const char *detail) {
    if (!response) {
        return;
    }
    response->result_code = TR_ERROR_BACKEND;
    snprintf(response->error, sizeof(response->error), "%s: %s", backend, detail && detail[0] ? detail : "backend error");
}

static void tr__set_timeout_error(tr_response *response, const char *backend) {
    if (!response) {
        return;
    }
    response->result_code = TR_ERROR_TIMEOUT;
    snprintf(response->error, sizeof(response->error), "%s: timeout", backend);
}

static void *tr__alloc(tr_client *client, size_t size) {
    return client->alloc_fn(size, client->allocator_user);
}

static void tr__free(tr_client *client, void *ptr) {
    if (ptr) {
        client->free_fn(ptr, client->allocator_user);
    }
}

static void tr__unlink_async(tr_client *client, tr_async *async_request) {
    tr_async **cursor = &client->async_head;
    while (*cursor) {
        if (*cursor == async_request) {
            *cursor = async_request->next;
            return;
        }
        cursor = &(*cursor)->next;
    }
}

static char *tr__dup_n(tr_client *client, const char *src, size_t len) {
    char *dst = (char *) tr__alloc(client, len + 1);
    if (!dst) {
        return NULL;
    }
    if (len) {
        memcpy(dst, src, len);
    }
    dst[len] = '\0';
    return dst;
}

static char *tr__dup(tr_client *client, const char *src) {
    if (!src) {
        return NULL;
    }
    return tr__dup_n(client, src, strlen(src));
}

static int tr__append_bytes(tr_client *client, tr_response *response, const void *data, size_t data_size) {
    unsigned char *new_body;
    if (!data_size) {
        return TR_OK;
    }
    /* yap: a response that is too large is refused, as if memory had run out */
    if (client->max_response_size && response->body_size + data_size > client->max_response_size) {
        return TR_ERROR_NOMEM;
    }
    new_body = (unsigned char *) tr__alloc(client, response->body_size + data_size + 1);
    if (!new_body) {
        return TR_ERROR_NOMEM;
    }
    if (response->body && response->body_size) {
        memcpy(new_body, response->body, response->body_size);
    }
    memcpy(new_body + response->body_size, data, data_size);
    new_body[response->body_size + data_size] = 0;
    tr__free(client, response->body);
    response->body = new_body;
    response->body_size += data_size;
    response->_free_fn = client->free_fn;
    response->_free_user = client->allocator_user;
    return TR_OK;
}

static int tr__append_header(tr_client *client, tr_response *response, const char *name, size_t name_len, const char *value, size_t value_len) {
    tr_owned_header *new_headers;
    tr_owned_header *slot;
    if (!name || !value) {
        return TR_ERROR_INVALID_ARGUMENT;
    }
    new_headers = (tr_owned_header *) tr__alloc(client, (response->header_count + 1) * sizeof(*new_headers));
    if (!new_headers) {
        return TR_ERROR_NOMEM;
    }
    if (response->headers && response->header_count) {
        memcpy(new_headers, response->headers, response->header_count * sizeof(*new_headers));
    }
    tr__free(client, response->headers);
    response->headers = new_headers;
    slot = &response->headers[response->header_count];
    slot->name = tr__dup_n(client, name, name_len);
    slot->value = tr__dup_n(client, value, value_len);
    if (!slot->name || !slot->value) {
        tr__free(client, slot->name);
        tr__free(client, slot->value);
        slot->name = NULL;
        slot->value = NULL;
        return TR_ERROR_NOMEM;
    }
    response->header_count += 1;
    return TR_OK;
}

static void tr__trim_ascii_span(const char **begin, size_t *len) {
    const char *p = *begin;
    size_t n = *len;
    while (n > 0 && (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')) {
        p += 1;
        n -= 1;
    }
    while (n > 0 && (p[n - 1] == ' ' || p[n - 1] == '\t' || p[n - 1] == '\r' || p[n - 1] == '\n')) {
        n -= 1;
    }
    *begin = p;
    *len = n;
}

static int tr__append_header_line(tr_client *client, tr_response *response, const char *line, size_t line_len) {
    const char *colon;
    const char *name;
    const char *value;
    size_t name_len;
    size_t value_len;
    if (!line || line_len == 0) {
        return TR_OK;
    }
    colon = (const char *) memchr(line, ':', line_len);
    if (!colon) {
        return TR_OK;
    }
    name = line;
    name_len = (size_t) (colon - line);
    value = colon + 1;
    value_len = line_len - name_len - 1;
    tr__trim_ascii_span(&name, &name_len);
    tr__trim_ascii_span(&value, &value_len);
    if (name_len == 0) {
        return TR_OK;
    }
    return tr__append_header(client, response, name, name_len, value, value_len);
}

void tr_response_cleanup(tr_response *response) {
    size_t i;
    if (!response) {
        return;
    }
    if (response->body && response->_free_fn) {
        response->_free_fn(response->body, response->_free_user);
    }
    if (response->headers && response->_free_fn) {
        for (i = 0; i < response->header_count; ++i) {
            response->_free_fn(response->headers[i].name, response->_free_user);
            response->_free_fn(response->headers[i].value, response->_free_user);
        }
        response->_free_fn(response->headers, response->_free_user);
    }
    tr__response_reset(response);
}

const char *tr_client_backend_name(const tr_client *client) {
    return client ? client->backend_name : "none";
}

#if !defined(_WIN32) && !defined(__APPLE__)
enum {
    TR__CURLMSG_DONE = 1,
    TR__CURLOPT_WRITEDATA = 10001,
    TR__CURLOPT_URL = 10002,
    TR__CURLOPT_POST = 47,
    TR__CURLOPT_HTTPHEADER = 10023,
    TR__CURLOPT_CUSTOMREQUEST = 10036,
    TR__CURLOPT_WRITEFUNCTION = 20011,
    TR__CURLOPT_FOLLOWLOCATION = 52,
    TR__CURLOPT_MAXREDIRS = 68,
    TR__CURLOPT_PROTOCOLS = 181,
    TR__CURLOPT_REDIR_PROTOCOLS = 182,
    TR__CURLOPT_POSTFIELDS = 10015,
    TR__CURLOPT_TIMEOUT_MS = 155,
    TR__CURLOPT_NOSIGNAL = 99,
    TR__CURLOPT_HTTPGET = 80,
    TR__CURLOPT_PRIVATE = 10103,
    TR__CURLOPT_POSTFIELDSIZE_LARGE = 30120,
    TR__CURLOPT_HEADERDATA = 10029,
    TR__CURLOPT_HEADERFUNCTION = 20079,
    TR__CURLINFO_RESPONSE_CODE = 0x200002
};

static const char *tr__curl_candidates[] = {
    "libcurl.so",
    "libcurl.so.4",
    "libcurl-gnutls.so.4",
    "libcurl.dylib",
    "/usr/lib/libcurl.dylib",
    "/opt/homebrew/opt/curl/lib/libcurl.dylib"
};

static int tr__curl_load_symbol(void **out, void *handle, const char *name) {
    *out = dlsym(handle, name);
    return *out ? TR_OK : TR_ERROR_BACKEND;
}

static int tr__curl_load_vtable(void *handle, tr_curl_vtable *vt) {
    if (tr__curl_load_symbol((void **) &vt->easy_init, handle, "curl_easy_init") != TR_OK) return TR_ERROR_BACKEND;
    if (tr__curl_load_symbol((void **) &vt->easy_setopt, handle, "curl_easy_setopt") != TR_OK) return TR_ERROR_BACKEND;
    if (tr__curl_load_symbol((void **) &vt->easy_perform, handle, "curl_easy_perform") != TR_OK) return TR_ERROR_BACKEND;
    if (tr__curl_load_symbol((void **) &vt->easy_cleanup, handle, "curl_easy_cleanup") != TR_OK) return TR_ERROR_BACKEND;
    if (tr__curl_load_symbol((void **) &vt->easy_getinfo, handle, "curl_easy_getinfo") != TR_OK) return TR_ERROR_BACKEND;
    if (tr__curl_load_symbol((void **) &vt->easy_strerror, handle, "curl_easy_strerror") != TR_OK) return TR_ERROR_BACKEND;
    if (tr__curl_load_symbol((void **) &vt->multi_init, handle, "curl_multi_init") != TR_OK) return TR_ERROR_BACKEND;
    if (tr__curl_load_symbol((void **) &vt->multi_add_handle, handle, "curl_multi_add_handle") != TR_OK) return TR_ERROR_BACKEND;
    if (tr__curl_load_symbol((void **) &vt->multi_remove_handle, handle, "curl_multi_remove_handle") != TR_OK) return TR_ERROR_BACKEND;
    if (tr__curl_load_symbol((void **) &vt->multi_perform, handle, "curl_multi_perform") != TR_OK) return TR_ERROR_BACKEND;
    if (tr__curl_load_symbol((void **) &vt->multi_info_read, handle, "curl_multi_info_read") != TR_OK) return TR_ERROR_BACKEND;
    if (tr__curl_load_symbol((void **) &vt->multi_cleanup, handle, "curl_multi_cleanup") != TR_OK) return TR_ERROR_BACKEND;
    if (tr__curl_load_symbol((void **) &vt->slist_append, handle, "curl_slist_append") != TR_OK) return TR_ERROR_BACKEND;
    if (tr__curl_load_symbol((void **) &vt->slist_free_all, handle, "curl_slist_free_all") != TR_OK) return TR_ERROR_BACKEND;
    return TR_OK;
}

static void *tr__curl_find_library(const char *path_hint, int *owns_handle, tr_curl_vtable *vt) {
    size_t i;
    void *handle = NULL;
    *owns_handle = 0;
    if (path_hint && path_hint[0]) {
        handle = dlopen(path_hint, RTLD_LAZY | RTLD_LOCAL);
        if (handle && tr__curl_load_vtable(handle, vt) == TR_OK) {
            *owns_handle = 1;
            return handle;
        }
        if (handle) {
            dlclose(handle);
        }
    }
    for (i = 0; i < sizeof(tr__curl_candidates) / sizeof(tr__curl_candidates[0]); ++i) {
        handle = dlopen(tr__curl_candidates[i], RTLD_LAZY | RTLD_LOCAL);
        if (handle && tr__curl_load_vtable(handle, vt) == TR_OK) {
            *owns_handle = 1;
            return handle;
        }
        if (handle) {
            dlclose(handle);
        }
    }
    return NULL;
}

static size_t tr__curl_write_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
    tr_async *async_request = (tr_async *) userdata;
    size_t bytes = size * nmemb;
    if (tr__append_bytes(async_request->client, &async_request->response, ptr, bytes) != TR_OK) {
        async_request->result_code = TR_ERROR_NOMEM;
        return 0;
    }
    return bytes;
}

static size_t tr__curl_header_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
    tr_async *async_request = (tr_async *) userdata;
    size_t bytes = size * nmemb;
    size_t line_len = bytes;
    int rc;
    while (line_len > 0 && (ptr[line_len - 1] == '\r' || ptr[line_len - 1] == '\n')) {
        line_len -= 1;
    }
    rc = tr__append_header_line(async_request->client, &async_request->response, ptr, line_len);
    if (rc != TR_OK) {
        async_request->result_code = rc;
        return 0;
    }
    return bytes;
}

static int tr__curl_apply_request(tr_client *client, void *easy, tr_async *async_request, const tr_request *request, tr_curl_slist **out_headers) {
    size_t i;
    tr_curl_slist *headers = NULL;
    const char *method = request->method ? request->method : "GET";

    if (client->curl.easy_setopt(easy, TR__CURLOPT_URL, request->url) != 0) return TR_ERROR_BACKEND;
    if (client->curl.easy_setopt(easy, TR__CURLOPT_WRITEFUNCTION, tr__curl_write_cb) != 0) return TR_ERROR_BACKEND;
    if (client->curl.easy_setopt(easy, TR__CURLOPT_WRITEDATA, async_request) != 0) return TR_ERROR_BACKEND;
    if (client->curl.easy_setopt(easy, TR__CURLOPT_HEADERFUNCTION, tr__curl_header_cb) != 0) return TR_ERROR_BACKEND;
    if (client->curl.easy_setopt(easy, TR__CURLOPT_HEADERDATA, async_request) != 0) return TR_ERROR_BACKEND;
    if (client->curl.easy_setopt(easy, TR__CURLOPT_FOLLOWLOCATION, 1L) != 0) return TR_ERROR_BACKEND;
    /* yap: http and https only (CURLPROTO_HTTP | CURLPROTO_HTTPS), also after a redirect */
    if (client->curl.easy_setopt(easy, TR__CURLOPT_PROTOCOLS, 3L) != 0) return TR_ERROR_BACKEND;
    if (client->curl.easy_setopt(easy, TR__CURLOPT_REDIR_PROTOCOLS, 3L) != 0) return TR_ERROR_BACKEND;
    if (client->curl.easy_setopt(easy, TR__CURLOPT_MAXREDIRS, 5L) != 0) return TR_ERROR_BACKEND;
    if (client->curl.easy_setopt(easy, TR__CURLOPT_NOSIGNAL, 1L) != 0) return TR_ERROR_BACKEND;
    if (request->timeout_ms > 0 && client->curl.easy_setopt(easy, TR__CURLOPT_TIMEOUT_MS, request->timeout_ms) != 0) return TR_ERROR_BACKEND;
    if (client->curl.easy_setopt(easy, TR__CURLOPT_PRIVATE, async_request) != 0) return TR_ERROR_BACKEND;

    for (i = 0; i < request->header_count; ++i) {
        size_t name_len = strlen(request->headers[i].name);
        size_t value_len = strlen(request->headers[i].value);
        char *line = (char *) tr__alloc(client, name_len + value_len + 3);
        if (!line) {
            if (headers) client->curl.slist_free_all(headers);
            return TR_ERROR_NOMEM;
        }
        memcpy(line, request->headers[i].name, name_len);
        line[name_len] = ':';
        line[name_len + 1] = ' ';
        memcpy(line + name_len + 2, request->headers[i].value, value_len);
        line[name_len + value_len + 2] = '\0';
        headers = client->curl.slist_append(headers, line);
        tr__free(client, line);
        if (!headers) {
            return TR_ERROR_NOMEM;
        }
    }

    if (headers && client->curl.easy_setopt(easy, TR__CURLOPT_HTTPHEADER, headers) != 0) {
        client->curl.slist_free_all(headers);
        return TR_ERROR_BACKEND;
    }

    if (strcmp(method, "GET") == 0) {
        if (client->curl.easy_setopt(easy, TR__CURLOPT_HTTPGET, 1L) != 0) {
            if (headers) client->curl.slist_free_all(headers);
            return TR_ERROR_BACKEND;
        }
    } else if (strcmp(method, "POST") == 0) {
        if (client->curl.easy_setopt(easy, TR__CURLOPT_POST, 1L) != 0) {
            if (headers) client->curl.slist_free_all(headers);
            return TR_ERROR_BACKEND;
        }
        if (request->body_size > 0) {
            if (client->curl.easy_setopt(easy, TR__CURLOPT_POSTFIELDS, async_request->body_copy) != 0) {
                if (headers) client->curl.slist_free_all(headers);
                return TR_ERROR_BACKEND;
            }
            if (client->curl.easy_setopt(easy, TR__CURLOPT_POSTFIELDSIZE_LARGE, (long long) request->body_size) != 0) {
                if (headers) client->curl.slist_free_all(headers);
                return TR_ERROR_BACKEND;
            }
        }
    } else {
        if (client->curl.easy_setopt(easy, TR__CURLOPT_CUSTOMREQUEST, async_request->method_copy) != 0) {
            if (headers) client->curl.slist_free_all(headers);
            return TR_ERROR_BACKEND;
        }
        if (request->body_size > 0) {
            if (client->curl.easy_setopt(easy, TR__CURLOPT_POSTFIELDS, async_request->body_copy) != 0) {
                if (headers) client->curl.slist_free_all(headers);
                return TR_ERROR_BACKEND;
            }
            if (client->curl.easy_setopt(easy, TR__CURLOPT_POSTFIELDSIZE_LARGE, (long long) request->body_size) != 0) {
                if (headers) client->curl.slist_free_all(headers);
                return TR_ERROR_BACKEND;
            }
        }
    }

    *out_headers = headers;
    return TR_OK;
}

static tr_async *tr__curl_find_async_by_easy(tr_client *client, void *easy) {
    tr_async *cursor = client->async_head;
    while (cursor) {
        if (cursor->easy == easy) {
            return cursor;
        }
        cursor = cursor->next;
    }
    return NULL;
}

static void tr__curl_destroy_async(tr_async *async_request) {
    tr_client *client;
    if (!async_request) {
        return;
    }
    client = async_request->client;
    if (async_request->added_to_multi && client->curl_multi && async_request->easy) {
        client->curl.multi_remove_handle(client->curl_multi, async_request->easy);
    }
    if (async_request->easy) {
        client->curl.easy_cleanup(async_request->easy);
    }
    if (async_request->headers) {
        client->curl.slist_free_all(async_request->headers);
    }
    tr__free(client, async_request->method_copy);
    tr__free(client, async_request->url_copy);
    tr__free(client, async_request->body_copy);
    tr_response_cleanup(&async_request->response);
    tr__free(client, async_request);
}
#elif defined(__APPLE__)
static CFStringRef tr__cfstring_from_utf8(tr_client *client, const char *text) {
    (void) client;
    if (!text) {
        return NULL;
    }
    return CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
}

static int tr__cfstring_copy_utf8(tr_client *client, CFStringRef string_ref, char **out_text) {
    CFIndex length;
    CFIndex max_size;
    char *buffer;
    if (!string_ref || !out_text) {
        return TR_ERROR_INVALID_ARGUMENT;
    }
    length = CFStringGetLength(string_ref);
    max_size = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
    buffer = (char *) tr__alloc(client, (size_t) max_size);
    if (!buffer) {
        return TR_ERROR_NOMEM;
    }
    if (!CFStringGetCString(string_ref, buffer, max_size, kCFStringEncodingUTF8)) {
        tr__free(client, buffer);
        return TR_ERROR_BACKEND;
    }
    *out_text = buffer;
    return TR_OK;
}

static void tr__cf_release(CFTypeRef object_ref) {
    if (object_ref) {
        CFRelease(object_ref);
    }
}

static void tr__apple_set_error(tr_async *async_request, int code, const char *message) {
    async_request->status = code;
    async_request->result_code = code;
    async_request->response.result_code = code;
    if (message && message[0]) {
        if (code == TR_ERROR_TIMEOUT) {
            snprintf(async_request->response.error, sizeof(async_request->response.error), "%s: timeout", "cfnetwork");
        } else if (code == TR_ERROR_BACKEND) {
            snprintf(async_request->response.error, sizeof(async_request->response.error), "%s: %s", "cfnetwork", message);
        } else {
            snprintf(async_request->response.error, sizeof(async_request->response.error), "%s", message);
        }
    }
}

static int tr__apple_apply_headers(tr_client *client, CFHTTPMessageRef message, const tr_request *request) {
    size_t i;
    for (i = 0; i < request->header_count; ++i) {
        CFStringRef name_ref = tr__cfstring_from_utf8(client, request->headers[i].name);
        CFStringRef value_ref = tr__cfstring_from_utf8(client, request->headers[i].value);
        if (!name_ref || !value_ref) {
            tr__cf_release(name_ref);
            tr__cf_release(value_ref);
            return TR_ERROR_NOMEM;
        }
        CFHTTPMessageSetHeaderFieldValue(message, name_ref, value_ref);
        tr__cf_release(name_ref);
        tr__cf_release(value_ref);
    }
    return TR_OK;
}

static int tr__apple_apply_body(CFHTTPMessageRef message, const void *body, size_t body_size) {
    CFDataRef body_ref;
    if (!body || body_size == 0) {
        return TR_OK;
    }
    body_ref = CFDataCreate(NULL, (const UInt8 *) body, (CFIndex) body_size);
    if (!body_ref) {
        return TR_ERROR_NOMEM;
    }
    CFHTTPMessageSetBody(message, body_ref);
    CFRelease(body_ref);
    return TR_OK;
}

static int tr__apple_build_request(tr_client *client, tr_async *async_request, const tr_request *request) {
    CFStringRef method_ref = NULL;
    CFStringRef url_ref_string = NULL;
    int rc;

    async_request->method_copy = tr__dup(client, request->method ? request->method : "GET");
    async_request->url_copy = tr__dup(client, request->url);
    async_request->body_size = request->body_size;
    if (!async_request->method_copy || !async_request->url_copy) {
        return TR_ERROR_NOMEM;
    }
    if (request->body_size > 0 && request->body) {
        async_request->body_copy = (unsigned char *) tr__alloc(client, request->body_size);
        if (!async_request->body_copy) {
            return TR_ERROR_NOMEM;
        }
        memcpy(async_request->body_copy, request->body, request->body_size);
    }

    method_ref = tr__cfstring_from_utf8(client, async_request->method_copy);
    url_ref_string = tr__cfstring_from_utf8(client, request->url);
    if (!method_ref || !url_ref_string) {
        tr__cf_release(method_ref);
        tr__cf_release(url_ref_string);
        return TR_ERROR_NOMEM;
    }
    async_request->url_ref = CFURLCreateWithString(NULL, url_ref_string, NULL);
    tr__cf_release(url_ref_string);
    if (!async_request->url_ref) {
        tr__cf_release(method_ref);
        return TR_ERROR_URL;
    }

    async_request->request_message = CFHTTPMessageCreateRequest(NULL, method_ref, async_request->url_ref, kCFHTTPVersion1_1);
    tr__cf_release(method_ref);
    if (!async_request->request_message) {
        return TR_ERROR_BACKEND;
    }
    rc = tr__apple_apply_headers(client, async_request->request_message, request);
    if (rc != TR_OK) {
        return rc;
    }
    return tr__apple_apply_body(async_request->request_message, async_request->body_copy, async_request->body_size);
}

static void tr__apple_capture_status(tr_async *async_request) {
    CFTypeRef property_ref;
    if (!async_request->stream || async_request->have_status_code) {
        return;
    }
    property_ref = CFReadStreamCopyProperty(async_request->stream, kCFStreamPropertyHTTPResponseHeader);
    if (property_ref) {
        if (CFGetTypeID(property_ref) == CFHTTPMessageGetTypeID()) {
            async_request->response.status_code = (long) CFHTTPMessageGetResponseStatusCode((CFHTTPMessageRef) property_ref);
            async_request->have_status_code = 1;
        }
        CFRelease(property_ref);
    }
}

static void tr__apple_dictionary_apply_header(const void *key, const void *value, void *context) {
    tr_async *async_request = (tr_async *) context;
    char *name = NULL;
    char *val = NULL;
    int rc;
    if (!key || !value) {
        return;
    }
    if (CFGetTypeID((CFTypeRef) key) != CFStringGetTypeID() || CFGetTypeID((CFTypeRef) value) != CFStringGetTypeID()) {
        return;
    }
    rc = tr__cfstring_copy_utf8(async_request->client, (CFStringRef) key, &name);
    if (rc != TR_OK) {
        async_request->result_code = rc;
        return;
    }
    rc = tr__cfstring_copy_utf8(async_request->client, (CFStringRef) value, &val);
    if (rc != TR_OK) {
        tr__free(async_request->client, name);
        async_request->result_code = rc;
        return;
    }
    rc = tr__append_header(async_request->client, &async_request->response, name, strlen(name), val, strlen(val));
    tr__free(async_request->client, name);
    tr__free(async_request->client, val);
    if (rc != TR_OK) {
        async_request->result_code = rc;
        return;
    }
}

static void tr__apple_capture_headers(tr_async *async_request) {
    CFTypeRef property_ref;
    CFDictionaryRef headers_ref;
    if (!async_request->stream || async_request->response.header_count > 0) {
        return;
    }
    property_ref = CFReadStreamCopyProperty(async_request->stream, kCFStreamPropertyHTTPResponseHeader);
    if (!property_ref) {
        return;
    }
    if (CFGetTypeID(property_ref) == CFHTTPMessageGetTypeID()) {
        headers_ref = CFHTTPMessageCopyAllHeaderFields((CFHTTPMessageRef) property_ref);
        if (headers_ref) {
            CFDictionaryApplyFunction(headers_ref, (CFDictionaryApplierFunction) tr__apple_dictionary_apply_header, async_request);
            CFRelease(headers_ref);
        }
    }
    CFRelease(property_ref);
}

static void tr__apple_finish_success(tr_async *async_request) {
    if (async_request->status != TR_IN_PROGRESS) {
        return;
    }
    async_request->status = TR_OK;
    async_request->result_code = TR_OK;
    async_request->response.result_code = TR_OK;
}

static void tr__apple_close_stream(tr_async *async_request) {
    if (async_request->stream && !async_request->stop_called) {
        async_request->stop_called = 1;
        CFReadStreamClose(async_request->stream);
    }
}

static void tr__apple_read_available(tr_async *async_request) {
    UInt8 buffer[4096];
    CFIndex bytes_read;
    while (async_request->stream && async_request->status == TR_IN_PROGRESS) {
        bytes_read = CFReadStreamRead(async_request->stream, buffer, (CFIndex) sizeof(buffer));
        if (bytes_read > 0) {
            if (tr__append_bytes(async_request->client, &async_request->response, buffer, (size_t) bytes_read) != TR_OK) {
                tr__apple_set_error(async_request, TR_ERROR_NOMEM, "response allocation failed");
                tr__apple_close_stream(async_request);
                return;
            }
            continue;
        }
        if (bytes_read == 0) {
            tr__apple_capture_status(async_request);
            tr__apple_finish_success(async_request);
            tr__apple_close_stream(async_request);
            return;
        }
        tr__apple_set_error(async_request, TR_ERROR_BACKEND, "read failed");
        tr__apple_close_stream(async_request);
        return;
    }
}

static void tr__apple_stream_cb(CFReadStreamRef stream, CFStreamEventType type, void *info) {
    tr_async *async_request = (tr_async *) info;
    (void) stream;
    if (!async_request) {
        return;
    }
    switch (type) {
        case kCFStreamEventOpenCompleted:
            async_request->opened = 1;
            tr__apple_capture_status(async_request);
            tr__apple_capture_headers(async_request);
            break;
        case kCFStreamEventHasBytesAvailable:
            tr__apple_capture_status(async_request);
            tr__apple_capture_headers(async_request);
            tr__apple_read_available(async_request);
            break;
        case kCFStreamEventEndEncountered:
            tr__apple_capture_status(async_request);
            tr__apple_capture_headers(async_request);
            tr__apple_finish_success(async_request);
            tr__apple_close_stream(async_request);
            break;
        case kCFStreamEventErrorOccurred:
            {
                CFStreamError stream_error = CFReadStreamGetError(async_request->stream);
                if (stream_error.error == ETIMEDOUT) {
                    tr__apple_set_error(async_request, TR_ERROR_TIMEOUT, "timeout");
                } else {
                    tr__apple_set_error(async_request, TR_ERROR_BACKEND, "stream error");
                }
            }
            tr__apple_close_stream(async_request);
            break;
    }
}

static void tr__apple_unschedule_async(tr_async *async_request) {
    if (async_request->stream && async_request->scheduled && async_request->run_loop) {
        CFReadStreamSetClient(async_request->stream, kCFStreamEventNone, NULL, NULL);
        CFReadStreamUnscheduleFromRunLoop(async_request->stream, async_request->run_loop, kCFRunLoopDefaultMode);
        async_request->scheduled = 0;
    }
}

static void tr__apple_cleanup_async(tr_async *async_request) {
    tr_client *client;
    if (!async_request) {
        return;
    }
    client = async_request->client;
    if (async_request->stream) {
        tr__apple_unschedule_async(async_request);
        tr__apple_close_stream(async_request);
    }
    tr__cf_release(async_request->stream);
    tr__cf_release(async_request->request_message);
    tr__cf_release(async_request->url_ref);
    tr__cf_release(async_request->run_loop);
    tr__free(client, async_request->method_copy);
    tr__free(client, async_request->url_copy);
    tr__free(client, async_request->body_copy);
    tr_response_cleanup(&async_request->response);
}

static void tr__apple_destroy_async(tr_async *async_request) {
    if (!async_request) {
        return;
    }
    tr__apple_cleanup_async(async_request);
    tr__free(async_request->client, async_request);
}

static int tr__apple_start_async(tr_client *client, tr_async *async_request, const tr_request *request) {
    CFStreamClientContext context;
    int rc;
    memset(&context, 0, sizeof(context));
    rc = tr__apple_build_request(client, async_request, request);
    if (rc != TR_OK) {
        return rc;
    }
    async_request->stream = CFReadStreamCreateForHTTPRequest(NULL, async_request->request_message);
    if (!async_request->stream) {
        return TR_ERROR_BACKEND;
    }
    CFReadStreamSetProperty(async_request->stream, kCFStreamPropertyHTTPShouldAutoredirect, kCFBooleanTrue);
    async_request->run_loop = CFRunLoopGetCurrent();
    if (async_request->run_loop) {
        CFRetain(async_request->run_loop);
    }
    if (request->timeout_ms > 0) {
        async_request->deadline = CFAbsoluteTimeGetCurrent() + ((CFAbsoluteTime) request->timeout_ms / 1000.0);
        async_request->has_deadline = 1;
    }
    context.info = async_request;
    if (!CFReadStreamSetClient(async_request->stream, kCFStreamEventOpenCompleted | kCFStreamEventHasBytesAvailable | kCFStreamEventEndEncountered | kCFStreamEventErrorOccurred, tr__apple_stream_cb, &context)) {
        return TR_ERROR_BACKEND;
    }
    if (!async_request->run_loop) {
        return TR_ERROR_BACKEND;
    }
    CFReadStreamScheduleWithRunLoop(async_request->stream, async_request->run_loop, kCFRunLoopDefaultMode);
    async_request->scheduled = 1;
    if (!CFReadStreamOpen(async_request->stream)) {
        return TR_ERROR_BACKEND;
    }
    return TR_OK;
}
#else
typedef struct tr__url_parts {
    int secure;
    INTERNET_PORT port;
    char *host;
    char *path;
} tr__url_parts;

static int tr__url_parse(tr_client *client, const char *url, tr__url_parts *parts) {
    const char *scheme_end;
    const char *host_begin;
    const char *host_end;
    const char *path_begin;
    const char *port_begin = NULL;
    int is_ipv6 = 0;
    size_t host_len;
    memset(parts, 0, sizeof(*parts));
    scheme_end = strstr(url, "://");
    if (!scheme_end) {
        return TR_ERROR_URL;
    }
    if ((size_t) (scheme_end - url) == 5 && _strnicmp(url, "https", 5) == 0) {
        parts->secure = 1;
        parts->port = INTERNET_DEFAULT_HTTPS_PORT;
    } else if ((size_t) (scheme_end - url) == 4 && _strnicmp(url, "http", 4) == 0) {
        parts->secure = 0;
        parts->port = INTERNET_DEFAULT_HTTP_PORT;
    } else {
        return TR_ERROR_URL;
    }
    host_begin = scheme_end + 3;
    if (*host_begin == '[') {
        const char *after_bracket;
        is_ipv6 = 1;
        host_begin += 1;
        host_end = strchr(host_begin, ']');
        if (!host_end) {
            return TR_ERROR_URL;
        }
        after_bracket = host_end + 1;
        path_begin = strchr(after_bracket, '/');
        if (!path_begin) {
            path_begin = after_bracket + strlen(after_bracket);
        }
        if (*after_bracket == ':') {
            port_begin = after_bracket + 1;
        }
    } else {
        path_begin = strchr(host_begin, '/');
        host_end = path_begin ? path_begin : host_begin + strlen(host_begin);
        if (!path_begin) {
            path_begin = host_end;
        }
        port_begin = memchr(host_begin, ':', (size_t) (host_end - host_begin));
    }

    if (port_begin) {
        parts->port = (INTERNET_PORT) strtoul(port_begin, NULL, 10);
        if (is_ipv6) {
            host_len = (size_t) (host_end - host_begin);
        } else {
            host_len = (size_t) (port_begin - host_begin - 1);
        }
    } else {
        host_len = (size_t) (host_end - host_begin);
    }
    if (!host_len) {
        return TR_ERROR_URL;
    }

    parts->host = tr__dup_n(client, host_begin, host_len);
    parts->path = tr__dup(client, *path_begin ? path_begin : "/");
    if (!parts->host || !parts->path) {
        tr__free(client, parts->host);
        tr__free(client, parts->path);
        return TR_ERROR_NOMEM;
    }
    return TR_OK;
}

static void tr__url_cleanup(tr_client *client, tr__url_parts *parts) {
    tr__free(client, parts->host);
    tr__free(client, parts->path);
}

static wchar_t *tr__utf8_to_wide(tr_client *client, const char *text) {
    int chars_needed;
    wchar_t *wide;
    chars_needed = MultiByteToWideChar(CP_UTF8, 0, text, -1, NULL, 0);
    if (chars_needed <= 0) {
        return NULL;
    }
    wide = (wchar_t *) tr__alloc(client, (size_t) chars_needed * sizeof(wchar_t));
    if (!wide) {
        return NULL;
    }
    if (MultiByteToWideChar(CP_UTF8, 0, text, -1, wide, chars_needed) <= 0) {
        tr__free(client, wide);
        return NULL;
    }
    return wide;
}

static int tr__winhttp_add_headers(tr_client *client, HINTERNET request_handle, const tr_request *request) {
    size_t i;
    for (i = 0; i < request->header_count; ++i) {
        size_t name_len = strlen(request->headers[i].name);
        size_t value_len = strlen(request->headers[i].value);
        char *line = (char *) tr__alloc(client, name_len + value_len + 5);
        wchar_t *wide = NULL;
        BOOL ok;
        if (!line) {
            return TR_ERROR_NOMEM;
        }
        memcpy(line, request->headers[i].name, name_len);
        line[name_len] = ':';
        line[name_len + 1] = ' ';
        memcpy(line + name_len + 2, request->headers[i].value, value_len);
        line[name_len + value_len + 2] = '\r';
        line[name_len + value_len + 3] = '\n';
        line[name_len + value_len + 4] = '\0';
        wide = tr__utf8_to_wide(client, line);
        tr__free(client, line);
        if (!wide) {
            return TR_ERROR_BACKEND;
        }
        ok = WinHttpAddRequestHeaders(request_handle, wide, (DWORD) -1L, WINHTTP_ADDREQ_FLAG_ADD);
        tr__free(client, wide);
        if (!ok) {
            return TR_ERROR_BACKEND;
        }
    }
    return TR_OK;
}

static int tr__wide_to_utf8(tr_client *client, const wchar_t *text, size_t chars, char **out_text) {
    int bytes_needed;
    char *buffer;
    if (!text || !out_text) {
        return TR_ERROR_INVALID_ARGUMENT;
    }
    bytes_needed = WideCharToMultiByte(CP_UTF8, 0, text, (int) chars, NULL, 0, NULL, NULL);
    if (bytes_needed <= 0) {
        return TR_ERROR_BACKEND;
    }
    buffer = (char *) tr__alloc(client, (size_t) bytes_needed + 1);
    if (!buffer) {
        return TR_ERROR_NOMEM;
    }
    if (WideCharToMultiByte(CP_UTF8, 0, text, (int) chars, buffer, bytes_needed, NULL, NULL) <= 0) {
        tr__free(client, buffer);
        return TR_ERROR_BACKEND;
    }
    buffer[bytes_needed] = '\0';
    *out_text = buffer;
    return TR_OK;
}

static int tr__winhttp_capture_headers(tr_client *client, HINTERNET request_handle, tr_response *response) {
    DWORD size = 0;
    wchar_t *raw = NULL;
    wchar_t *cursor;
    int rc;
    if (!WinHttpQueryHeaders(request_handle, WINHTTP_QUERY_RAW_HEADERS_CRLF, WINHTTP_HEADER_NAME_BY_INDEX, NULL, &size, WINHTTP_NO_HEADER_INDEX)) {
        DWORD error_code = GetLastError();
        if (error_code != ERROR_INSUFFICIENT_BUFFER) {
            return TR_ERROR_BACKEND;
        }
    }
    if (size == 0) {
        return TR_OK;
    }
    raw = (wchar_t *) tr__alloc(client, size);
    if (!raw) {
        return TR_ERROR_NOMEM;
    }
    if (!WinHttpQueryHeaders(request_handle, WINHTTP_QUERY_RAW_HEADERS_CRLF, WINHTTP_HEADER_NAME_BY_INDEX, raw, &size, WINHTTP_NO_HEADER_INDEX)) {
        tr__free(client, raw);
        return TR_ERROR_BACKEND;
    }
    cursor = raw;
    while (*cursor) {
        wchar_t *line_end = wcschr(cursor, L'\r');
        wchar_t *next = NULL;
        if (!line_end) {
            line_end = cursor + wcslen(cursor);
        }
        if (*line_end == L'\r' && line_end[1] == L'\n') {
            next = line_end + 2;
        } else {
            next = line_end + (*line_end ? 1 : 0);
        }
        if (wcschr(cursor, L':')) {
            char *utf8_line = NULL;
            rc = tr__wide_to_utf8(client, cursor, (size_t) (line_end - cursor), &utf8_line);
            if (rc != TR_OK) {
                tr__free(client, raw);
                return rc;
            }
            rc = tr__append_header_line(client, response, utf8_line, strlen(utf8_line));
            tr__free(client, utf8_line);
            if (rc != TR_OK) {
                tr__free(client, raw);
                return rc;
            }
        }
        cursor = next;
    }
    tr__free(client, raw);
    return TR_OK;
}

static void tr__winhttp_set_error(tr_async *async_request, int result_code, const char *message) {
    EnterCriticalSection(&async_request->lock);
    async_request->status = result_code;
    async_request->result_code = result_code;
    async_request->response.result_code = result_code;
    if (message && message[0]) {
        if (result_code == TR_ERROR_TIMEOUT) {
            snprintf(async_request->response.error, sizeof(async_request->response.error), "%s: timeout", "winhttp");
        } else if (result_code == TR_ERROR_BACKEND) {
            snprintf(async_request->response.error, sizeof(async_request->response.error), "%s: %s", "winhttp", message);
        } else {
            snprintf(async_request->response.error, sizeof(async_request->response.error), "%s", message);
        }
    }
    LeaveCriticalSection(&async_request->lock);
}

static void tr__winhttp_set_win32_error(tr_async *async_request, const char *api_name, DWORD error_code) {
    char message[128];
    if (error_code == ERROR_WINHTTP_TIMEOUT) {
        tr__winhttp_set_error(async_request, TR_ERROR_TIMEOUT, "timeout");
        return;
    }
    snprintf(message, sizeof(message), "%s failed (%lu)", api_name, (unsigned long) error_code);
    tr__winhttp_set_error(async_request, TR_ERROR_BACKEND, message);
}

static int tr__winhttp_is_pending(BOOL ok) {
    if (ok) {
        return 1;
    }
    return GetLastError() == ERROR_IO_PENDING;
}

static void tr__winhttp_finish_success(tr_async *async_request) {
    EnterCriticalSection(&async_request->lock);
    async_request->status = TR_OK;
    async_request->result_code = TR_OK;
    async_request->response.result_code = TR_OK;
    LeaveCriticalSection(&async_request->lock);
}

static void CALLBACK tr__winhttp_status_cb(HINTERNET handle, DWORD_PTR context, DWORD status, LPVOID info, DWORD info_len) {
    tr_async *async_request = (tr_async *) context;
    DWORD status_code_size;
    DWORD status_code;
    DWORD available;
    unsigned char *buffer;
    (void) handle;

    if (!async_request) {
        return;
    }

    switch (status) {
        case WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE:
            if (!tr__winhttp_is_pending(WinHttpReceiveResponse(async_request->request_handle, NULL))) {
                tr__winhttp_set_win32_error(async_request, "WinHttpReceiveResponse", GetLastError());
            }
            break;

        case WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE:
            status_code = 0;
            status_code_size = sizeof(status_code);
            if (!WinHttpQueryHeaders(async_request->request_handle, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, &status_code, &status_code_size, WINHTTP_NO_HEADER_INDEX)) {
                tr__winhttp_set_win32_error(async_request, "WinHttpQueryHeaders", GetLastError());
                break;
            }
            EnterCriticalSection(&async_request->lock);
            async_request->response.status_code = (long) status_code;
            if (tr__winhttp_capture_headers(async_request->client, async_request->request_handle, &async_request->response) != TR_OK) {
                async_request->status = TR_ERROR_BACKEND;
                async_request->result_code = TR_ERROR_BACKEND;
                async_request->response.result_code = TR_ERROR_BACKEND;
                snprintf(async_request->response.error, sizeof(async_request->response.error), "%s: %s", "winhttp", "header extraction failed");
            }
            LeaveCriticalSection(&async_request->lock);
            if (!tr__winhttp_is_pending(WinHttpQueryDataAvailable(async_request->request_handle, NULL))) {
                tr__winhttp_set_win32_error(async_request, "WinHttpQueryDataAvailable", GetLastError());
            }
            break;

        case WINHTTP_CALLBACK_STATUS_DATA_AVAILABLE:
            available = *(DWORD *) info;
            if (available == 0) {
                tr__winhttp_finish_success(async_request);
                break;
            }
            buffer = (unsigned char *) tr__alloc(async_request->client, available);
            if (!buffer) {
                tr__winhttp_set_error(async_request, TR_ERROR_NOMEM, "out of memory");
                break;
            }
            if (!tr__winhttp_is_pending(WinHttpReadData(async_request->request_handle, buffer, available, NULL))) {
                tr__free(async_request->client, buffer);
                tr__winhttp_set_win32_error(async_request, "WinHttpReadData", GetLastError());
            }
            break;

        case WINHTTP_CALLBACK_STATUS_READ_COMPLETE:
            if (info && info_len > 0) {
                EnterCriticalSection(&async_request->lock);
                if (tr__append_bytes(async_request->client, &async_request->response, info, (size_t) info_len) != TR_OK) {
                    async_request->status = TR_ERROR_NOMEM;
                    async_request->result_code = TR_ERROR_NOMEM;
                    async_request->response.result_code = TR_ERROR_NOMEM;
                    snprintf(async_request->response.error, sizeof(async_request->response.error), "%s", "out of memory");
                }
                LeaveCriticalSection(&async_request->lock);
            }
            tr__free(async_request->client, info);
            if (async_request->status == TR_IN_PROGRESS) {
                if (!tr__winhttp_is_pending(WinHttpQueryDataAvailable(async_request->request_handle, NULL))) {
                    tr__winhttp_set_win32_error(async_request, "WinHttpQueryDataAvailable", GetLastError());
                }
            }
            break;

        case WINHTTP_CALLBACK_STATUS_REQUEST_ERROR:
            {
                WINHTTP_ASYNC_RESULT *result = (WINHTTP_ASYNC_RESULT *) info;
                DWORD error_code = result ? result->dwError : GetLastError();
                tr__winhttp_set_win32_error(async_request, "WinHTTP request", error_code);
            }
            break;

        case WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING:
            InterlockedExchange(&async_request->handle_closed, 1);
            if (async_request->close_event) {
                SetEvent(async_request->close_event);
            }
            break;
    }
}

static void tr__winhttp_close_handles(tr_async *async_request) {
    if (InterlockedExchange(&async_request->close_started, 1) != 0) {
        return;
    }
    if (async_request->request_handle) {
        WinHttpCloseHandle(async_request->request_handle);
        async_request->request_handle = NULL;
    }
    if (async_request->connection) {
        WinHttpCloseHandle(async_request->connection);
        async_request->connection = NULL;
    }
    if (async_request->session) {
        WinHttpCloseHandle(async_request->session);
        async_request->session = NULL;
    }
}

static void tr__winhttp_destroy_async(tr_async *async_request) {
    tr_client *client;
    if (!async_request) {
        return;
    }
    client = async_request->client;
    tr__winhttp_close_handles(async_request);
    if (async_request->close_event && InterlockedCompareExchange(&async_request->handle_closed, 0, 0) == 0) {
        WaitForSingleObject(async_request->close_event, INFINITE);
    }
    if (async_request->close_event) {
        CloseHandle(async_request->close_event);
    }
    if (async_request->lock_ready) {
        DeleteCriticalSection(&async_request->lock);
    }
    tr__free(client, async_request->method_copy);
    tr__free(client, async_request->url_copy);
    tr__free(client, async_request->body_copy);
    tr_response_cleanup(&async_request->response);
    tr__free(client, async_request);
}
#endif

tr_client *tr_client_create(const tr_config *config) {
    tr_client bootstrap;
    tr_client *client;
    memset(&bootstrap, 0, sizeof(bootstrap));
    bootstrap.alloc_fn = (config && config->alloc_fn) ? config->alloc_fn : tr__default_alloc;
    bootstrap.free_fn = (config && config->free_fn) ? config->free_fn : tr__default_free;
    bootstrap.allocator_user = config ? config->allocator_user : NULL;

    client = (tr_client *) bootstrap.alloc_fn(sizeof(*client), bootstrap.allocator_user);
    if (!client) {
        return NULL;
    }
    memset(client, 0, sizeof(*client));
    client->alloc_fn = bootstrap.alloc_fn;
    client->free_fn = bootstrap.free_fn;
    client->allocator_user = bootstrap.allocator_user;
    client->max_response_size = config ? config->max_response_size : 0; /* yap */

#ifdef _WIN32
    client->backend_kind = 1;
    client->backend_name = "winhttp";
    (void) config;
#elif defined(__APPLE__)
    client->backend_kind = 3;
    client->backend_name = "cfnetwork";
    (void) config;
#else
    client->backend_kind = 2;
    client->backend_name = "libcurl";

    if (config && config->curl_vtable) {
        client->curl = *config->curl_vtable;
    } else if (config && config->curl_library_handle) {
        if (tr__curl_load_vtable(config->curl_library_handle, &client->curl) != TR_OK) {
            tr__free(client, client);
            return NULL;
        }
        client->curl_library_handle = config->curl_library_handle;
    } else {
        client->curl_library_handle = tr__curl_find_library(config ? config->curl_library_path : NULL, &client->owns_curl_handle, &client->curl);
        if (!client->curl_library_handle) {
            tr__free(client, client);
            return NULL;
        }
    }

    client->curl_multi = client->curl.multi_init();
    if (!client->curl_multi) {
        if (client->owns_curl_handle && client->curl_library_handle) {
            dlclose(client->curl_library_handle);
        }
        tr__free(client, client);
        return NULL;
    }
#endif

    return client;
}

void tr_client_destroy(tr_client *client) {
    if (!client) {
        return;
    }
    while (client->async_head) {
        tr_async *next = client->async_head->next;
#ifdef _WIN32
        tr__winhttp_destroy_async(client->async_head);
#elif defined(__APPLE__)
        tr__apple_destroy_async(client->async_head);
#else
        tr__curl_destroy_async(client->async_head);
#endif
        client->async_head = next;
    }
#if !defined(_WIN32) && !defined(__APPLE__)
    if (client->curl_multi) {
        client->curl.multi_cleanup(client->curl_multi);
    }
    if (client->owns_curl_handle && client->curl_library_handle) {
        dlclose(client->curl_library_handle);
    }
#endif
    client->free_fn(client, client->allocator_user);
}

int tr_request_perform(tr_client *client, const tr_request *request, tr_response *response) {
    if (!client || !request || !request->url || !response) {
        if (response) {
            tr__set_error(response, TR_ERROR_INVALID_ARGUMENT, "invalid argument");
        }
        return TR_ERROR_INVALID_ARGUMENT;
    }

    tr__response_reset(response);

#ifdef _WIN32
    {
        tr__url_parts parts;
        HINTERNET session = NULL;
        HINTERNET connection = NULL;
        HINTERNET request_handle = NULL;
        wchar_t *host_w = NULL;
        wchar_t *path_w = NULL;
        wchar_t *method_w = NULL;
        DWORD status_code = 0;
        DWORD status_code_size = sizeof(status_code);
        unsigned char buffer[4096];
        DWORD bytes_read = 0;
        int rc = tr__url_parse(client, request->url, &parts);
        if (rc != TR_OK) {
            tr__set_error(response, rc, "invalid url");
            return rc;
        }

        host_w = tr__utf8_to_wide(client, parts.host);
        path_w = tr__utf8_to_wide(client, parts.path);
        method_w = tr__utf8_to_wide(client, request->method ? request->method : "GET");
        if (!host_w || !path_w || !method_w) {
            rc = TR_ERROR_NOMEM;
            tr__set_error(response, rc, "wide string conversion failed");
            goto winhttp_cleanup;
        }

        session = WinHttpOpen(L"tinyrequests/0.1", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
        if (!session) {
            rc = TR_ERROR_BACKEND;
            tr__set_backend_error(response, "winhttp", "WinHttpOpen failed");
            goto winhttp_cleanup;
        }
        if (request->timeout_ms > 0) {
            WinHttpSetTimeouts(session, (int) request->timeout_ms, (int) request->timeout_ms, (int) request->timeout_ms, (int) request->timeout_ms);
        }
        connection = WinHttpConnect(session, host_w, parts.port, 0);
        if (!connection) {
            rc = TR_ERROR_BACKEND;
            tr__set_backend_error(response, "winhttp", "WinHttpConnect failed");
            goto winhttp_cleanup;
        }
        request_handle = WinHttpOpenRequest(connection, method_w, path_w, NULL, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, parts.secure ? WINHTTP_FLAG_SECURE : 0);
        if (!request_handle) {
            rc = TR_ERROR_BACKEND;
            tr__set_backend_error(response, "winhttp", "WinHttpOpenRequest failed");
            goto winhttp_cleanup;
        }
        rc = tr__winhttp_add_headers(client, request_handle, request);
        if (rc != TR_OK) {
            if (rc == TR_ERROR_NOMEM) {
                tr__set_error(response, rc, "out of memory");
            } else {
                tr__set_backend_error(response, "winhttp", "WinHttpAddRequestHeaders failed");
            }
            goto winhttp_cleanup;
        }
        if (!WinHttpSendRequest(request_handle, WINHTTP_NO_ADDITIONAL_HEADERS, 0, (LPVOID) request->body, (DWORD) request->body_size, (DWORD) request->body_size, 0)) {
            DWORD error_code = GetLastError();
            rc = (error_code == ERROR_WINHTTP_TIMEOUT) ? TR_ERROR_TIMEOUT : TR_ERROR_BACKEND;
            if (rc == TR_ERROR_TIMEOUT) {
                tr__set_timeout_error(response, "winhttp");
            } else {
                tr__set_backend_error(response, "winhttp", "WinHttpSendRequest failed");
            }
            goto winhttp_cleanup;
        }
        if (!WinHttpReceiveResponse(request_handle, NULL)) {
            DWORD error_code = GetLastError();
            rc = (error_code == ERROR_WINHTTP_TIMEOUT) ? TR_ERROR_TIMEOUT : TR_ERROR_BACKEND;
            if (rc == TR_ERROR_TIMEOUT) {
                tr__set_timeout_error(response, "winhttp");
            } else {
                tr__set_backend_error(response, "winhttp", "WinHttpReceiveResponse failed");
            }
            goto winhttp_cleanup;
        }
        if (!WinHttpQueryHeaders(request_handle, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, &status_code, &status_code_size, WINHTTP_NO_HEADER_INDEX)) {
            DWORD error_code = GetLastError();
            rc = (error_code == ERROR_WINHTTP_TIMEOUT) ? TR_ERROR_TIMEOUT : TR_ERROR_BACKEND;
            if (rc == TR_ERROR_TIMEOUT) {
                tr__set_timeout_error(response, "winhttp");
            } else {
                tr__set_backend_error(response, "winhttp", "WinHttpQueryHeaders failed");
            }
            goto winhttp_cleanup;
        }
        response->status_code = (long) status_code;
        response->result_code = TR_OK;
        response->_free_fn = client->free_fn;
        response->_free_user = client->allocator_user;
        rc = tr__winhttp_capture_headers(client, request_handle, response);
        if (rc != TR_OK) {
            if (rc == TR_ERROR_NOMEM) {
                tr__set_error(response, rc, "out of memory");
            } else {
                tr__set_backend_error(response, "winhttp", "WinHttpQueryHeaders failed");
            }
            goto winhttp_cleanup;
        }
        do {
            bytes_read = 0;
            if (!WinHttpReadData(request_handle, buffer, (DWORD) sizeof(buffer), &bytes_read)) {
                DWORD error_code = GetLastError();
                rc = (error_code == ERROR_WINHTTP_TIMEOUT) ? TR_ERROR_TIMEOUT : TR_ERROR_BACKEND;
                if (rc == TR_ERROR_TIMEOUT) {
                    tr__set_timeout_error(response, "winhttp");
                } else {
                    tr__set_backend_error(response, "winhttp", "WinHttpReadData failed");
                }
                goto winhttp_cleanup;
            }
            if (bytes_read > 0 && tr__append_bytes(client, response, buffer, bytes_read) != TR_OK) {
                rc = TR_ERROR_NOMEM;
                tr__set_error(response, rc, "out of memory");
                goto winhttp_cleanup;
            }
        } while (bytes_read > 0);
        rc = TR_OK;

winhttp_cleanup:
        tr__free(client, host_w);
        tr__free(client, path_w);
        tr__free(client, method_w);
        if (request_handle) WinHttpCloseHandle(request_handle);
        if (connection) WinHttpCloseHandle(connection);
        if (session) WinHttpCloseHandle(session);
        tr__url_cleanup(client, &parts);
        return rc;
    }
#elif defined(__APPLE__)
    {
        tr_async fake_async;
        int rc;
        memset(&fake_async, 0, sizeof(fake_async));
        fake_async.client = client;
        fake_async.status = TR_IN_PROGRESS;
        fake_async.result_code = TR_IN_PROGRESS;
        tr__response_reset(&fake_async.response);
        rc = tr__apple_start_async(client, &fake_async, request);
        if (rc != TR_OK) {
            tr__apple_cleanup_async(&fake_async);
            tr__set_error(response, rc, rc == TR_ERROR_URL ? "invalid url" : "CFNetwork setup failed");
            return rc;
        }
        while (fake_async.status == TR_IN_PROGRESS) {
            if (fake_async.has_deadline && CFAbsoluteTimeGetCurrent() >= fake_async.deadline) {
                tr__apple_set_error(&fake_async, TR_ERROR_BACKEND, "request timed out");
                tr__apple_close_stream(&fake_async);
                break;
            }
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, 0);
            tr__apple_read_available(&fake_async);
        }
        if (fake_async.status != TR_OK) {
            int error_code = fake_async.result_code;
            *response = fake_async.response;
            tr__response_reset(&fake_async.response);
            tr__apple_cleanup_async(&fake_async);
            return error_code;
        }
        *response = fake_async.response;
        tr__response_reset(&fake_async.response);
        tr__apple_cleanup_async(&fake_async);
        return TR_OK;
    }
#else
    {
        tr_async fake_async;
        void *easy = NULL;
        tr_curl_slist *headers = NULL;
        long status_code = 0;
        int curl_rc;
        memset(&fake_async, 0, sizeof(fake_async));
        fake_async.client = client;
        tr__response_reset(&fake_async.response);
        fake_async.method_copy = tr__dup(client, request->method ? request->method : "GET");
        fake_async.url_copy = tr__dup(client, request->url);
        if ((request->body_size > 0) && request->body) {
            fake_async.body_copy = (unsigned char *) tr__alloc(client, request->body_size);
            if (!fake_async.body_copy) {
                tr__set_error(response, TR_ERROR_NOMEM, "request allocation failed");
                tr__free(client, fake_async.method_copy);
                tr__free(client, fake_async.url_copy);
                return TR_ERROR_NOMEM;
            }
            memcpy(fake_async.body_copy, request->body, request->body_size);
        }
        easy = client->curl.easy_init();
        if (!easy) {
            tr__set_error(response, TR_ERROR_BACKEND, "curl_easy_init failed");
            tr__free(client, fake_async.method_copy);
            tr__free(client, fake_async.url_copy);
            tr__free(client, fake_async.body_copy);
            return TR_ERROR_BACKEND;
        }
        fake_async.easy = easy;
        curl_rc = tr__curl_apply_request(client, easy, &fake_async, request, &headers);
        if (curl_rc != TR_OK) {
            tr__set_error(response, curl_rc, "curl setup failed");
            client->curl.easy_cleanup(easy);
            tr__free(client, fake_async.method_copy);
            tr__free(client, fake_async.url_copy);
            tr__free(client, fake_async.body_copy);
            return curl_rc;
        }
        fake_async.headers = headers;
        curl_rc = client->curl.easy_perform(easy);
        if (curl_rc != 0) {
            const char *err = client->curl.easy_strerror ? client->curl.easy_strerror(curl_rc) : "request failed";
            int mapped_rc = (request->timeout_ms > 0 && strstr(err, "Timeout") != NULL) ? TR_ERROR_TIMEOUT : TR_ERROR_BACKEND;
            if (mapped_rc == TR_ERROR_TIMEOUT) {
                tr__set_timeout_error(response, "libcurl");
            } else {
                tr__set_backend_error(response, "libcurl", err);
            }
            client->curl.easy_cleanup(easy);
            if (headers) client->curl.slist_free_all(headers);
            tr_response_cleanup(&fake_async.response);
            tr__free(client, fake_async.method_copy);
            tr__free(client, fake_async.url_copy);
            tr__free(client, fake_async.body_copy);
            return mapped_rc;
        }
        if (client->curl.easy_getinfo(easy, TR__CURLINFO_RESPONSE_CODE, &status_code) != 0) {
            tr__set_backend_error(response, "libcurl", "curl_easy_getinfo failed");
            client->curl.easy_cleanup(easy);
            if (headers) client->curl.slist_free_all(headers);
            tr_response_cleanup(&fake_async.response);
            tr__free(client, fake_async.method_copy);
            tr__free(client, fake_async.url_copy);
            tr__free(client, fake_async.body_copy);
            return TR_ERROR_BACKEND;
        }
        *response = fake_async.response;
        response->status_code = status_code;
        response->result_code = TR_OK;
        tr__response_reset(&fake_async.response);
        client->curl.easy_cleanup(easy);
        if (headers) client->curl.slist_free_all(headers);
        tr__free(client, fake_async.method_copy);
        tr__free(client, fake_async.url_copy);
        tr__free(client, fake_async.body_copy);
        return TR_OK;
    }
#endif
}

int tr_request_begin(tr_client *client, const tr_request *request, tr_async **out_async) {
    if (!client || !request || !request->url || !out_async) {
        return TR_ERROR_INVALID_ARGUMENT;
    }

#ifdef _WIN32
    {
        tr__url_parts parts;
        tr_async *async_request;
        wchar_t *host_w = NULL;
        wchar_t *path_w = NULL;
        wchar_t *method_w = NULL;
        int rc;

        rc = tr__url_parse(client, request->url, &parts);
        if (rc != TR_OK) {
            return rc;
        }

        async_request = (tr_async *) tr__alloc(client, sizeof(*async_request));
        if (!async_request) {
            tr__url_cleanup(client, &parts);
            return TR_ERROR_NOMEM;
        }
        memset(async_request, 0, sizeof(*async_request));
        async_request->client = client;
        async_request->status = TR_IN_PROGRESS;
        async_request->result_code = TR_IN_PROGRESS;
        tr__response_reset(&async_request->response);
        InitializeCriticalSection(&async_request->lock);
        async_request->lock_ready = 1;
        async_request->close_event = CreateEventA(NULL, TRUE, FALSE, NULL);
        async_request->method_copy = tr__dup(client, request->method ? request->method : "GET");
        async_request->url_copy = tr__dup(client, request->url);
        async_request->body_size = request->body_size;
        if (!async_request->close_event || !async_request->method_copy || !async_request->url_copy) {
            tr__winhttp_destroy_async(async_request);
            tr__url_cleanup(client, &parts);
            return TR_ERROR_NOMEM;
        }
        if (request->body_size > 0 && request->body) {
            async_request->body_copy = (unsigned char *) tr__alloc(client, request->body_size);
            if (!async_request->body_copy) {
                tr__winhttp_destroy_async(async_request);
                tr__url_cleanup(client, &parts);
                return TR_ERROR_NOMEM;
            }
            memcpy(async_request->body_copy, request->body, request->body_size);
        }

        host_w = tr__utf8_to_wide(client, parts.host);
        path_w = tr__utf8_to_wide(client, parts.path);
        method_w = tr__utf8_to_wide(client, async_request->method_copy);
        if (!host_w || !path_w || !method_w) {
            tr__free(client, host_w);
            tr__free(client, path_w);
            tr__free(client, method_w);
            tr__winhttp_destroy_async(async_request);
            tr__url_cleanup(client, &parts);
            return TR_ERROR_NOMEM;
        }

        async_request->session = WinHttpOpen(L"tinyrequests/0.1", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, WINHTTP_FLAG_ASYNC);
        if (!async_request->session) {
            rc = TR_ERROR_BACKEND;
            goto win_async_fail;
        }
        if (request->timeout_ms > 0) {
            WinHttpSetTimeouts(async_request->session, (int) request->timeout_ms, (int) request->timeout_ms, (int) request->timeout_ms, (int) request->timeout_ms);
        }
        async_request->connection = WinHttpConnect(async_request->session, host_w, parts.port, 0);
        if (!async_request->connection) {
            rc = TR_ERROR_BACKEND;
            goto win_async_fail;
        }
        async_request->request_handle = WinHttpOpenRequest(async_request->connection, method_w, path_w, NULL, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, parts.secure ? WINHTTP_FLAG_SECURE : 0);
        if (!async_request->request_handle) {
            rc = TR_ERROR_BACKEND;
            goto win_async_fail;
        }
        if (WinHttpSetStatusCallback(async_request->request_handle, tr__winhttp_status_cb, WINHTTP_CALLBACK_FLAG_SENDREQUEST_COMPLETE | WINHTTP_CALLBACK_FLAG_HEADERS_AVAILABLE | WINHTTP_CALLBACK_FLAG_DATA_AVAILABLE | WINHTTP_CALLBACK_FLAG_READ_COMPLETE | WINHTTP_CALLBACK_FLAG_REQUEST_ERROR | WINHTTP_CALLBACK_FLAG_HANDLES, 0) == WINHTTP_INVALID_STATUS_CALLBACK) {
            rc = TR_ERROR_BACKEND;
            goto win_async_fail;
        }
        rc = tr__winhttp_add_headers(client, async_request->request_handle, request);
        if (rc != TR_OK) {
            goto win_async_fail;
        }
        async_request->next = client->async_head;
        client->async_head = async_request;
        if (!WinHttpSendRequest(async_request->request_handle, WINHTTP_NO_ADDITIONAL_HEADERS, 0, (LPVOID) async_request->body_copy, (DWORD) async_request->body_size, (DWORD) async_request->body_size, (DWORD_PTR) async_request)) {
            DWORD error_code = GetLastError();
            if (error_code != ERROR_IO_PENDING) {
                tr__unlink_async(client, async_request);
                tr__free(client, host_w);
                tr__free(client, path_w);
                tr__free(client, method_w);
                tr__url_cleanup(client, &parts);
                tr__winhttp_destroy_async(async_request);
                return TR_ERROR_BACKEND;
            }
        }
        tr__free(client, host_w);
        tr__free(client, path_w);
        tr__free(client, method_w);
        tr__url_cleanup(client, &parts);
        *out_async = async_request;
        return TR_OK;

win_async_fail:
        tr__free(client, host_w);
        tr__free(client, path_w);
        tr__free(client, method_w);
        tr__url_cleanup(client, &parts);
        tr__winhttp_destroy_async(async_request);
        return rc;
    }
#elif defined(__APPLE__)
    {
        tr_async *async_request = (tr_async *) tr__alloc(client, sizeof(*async_request));
        int rc;
        if (!async_request) {
            return TR_ERROR_NOMEM;
        }
        memset(async_request, 0, sizeof(*async_request));
        async_request->client = client;
        async_request->status = TR_IN_PROGRESS;
        async_request->result_code = TR_IN_PROGRESS;
        tr__response_reset(&async_request->response);
        rc = tr__apple_start_async(client, async_request, request);
        if (rc != TR_OK) {
            tr__apple_destroy_async(async_request);
            return rc;
        }
        async_request->next = client->async_head;
        client->async_head = async_request;
        *out_async = async_request;
        return TR_OK;
    }
#else
    {
        tr_async *async_request = (tr_async *) tr__alloc(client, sizeof(*async_request));
        int rc;
        if (!async_request) {
            return TR_ERROR_NOMEM;
        }
        memset(async_request, 0, sizeof(*async_request));
        async_request->client = client;
        async_request->status = TR_IN_PROGRESS;
        async_request->result_code = TR_IN_PROGRESS;
        tr__response_reset(&async_request->response);
        async_request->method_copy = tr__dup(client, request->method ? request->method : "GET");
        async_request->url_copy = tr__dup(client, request->url);
        async_request->body_size = request->body_size;
        if (!async_request->method_copy || !async_request->url_copy) {
            tr__curl_destroy_async(async_request);
            return TR_ERROR_NOMEM;
        }
        if (request->body_size > 0 && request->body) {
            async_request->body_copy = (unsigned char *) tr__alloc(client, request->body_size);
            if (!async_request->body_copy) {
                tr__curl_destroy_async(async_request);
                return TR_ERROR_NOMEM;
            }
            memcpy(async_request->body_copy, request->body, request->body_size);
        }
        async_request->easy = client->curl.easy_init();
        if (!async_request->easy) {
            tr__curl_destroy_async(async_request);
            return TR_ERROR_BACKEND;
        }
        rc = tr__curl_apply_request(client, async_request->easy, async_request, request, &async_request->headers);
        if (rc != TR_OK) {
            tr__curl_destroy_async(async_request);
            return rc;
        }
        if (client->curl.multi_add_handle(client->curl_multi, async_request->easy) != 0) {
            tr__curl_destroy_async(async_request);
            return TR_ERROR_BACKEND;
        }
        async_request->added_to_multi = 1;
        async_request->next = client->async_head;
        client->async_head = async_request;
        *out_async = async_request;
        return TR_OK;
    }
#endif
}

size_t tr_client_poll(tr_client *client) {
    if (!client) {
        return 0;
    }

#ifdef _WIN32
    {
        size_t pending = 0;
        tr_async *cursor;
        for (cursor = client->async_head; cursor; cursor = cursor->next) {
            if (cursor->status == TR_IN_PROGRESS) {
                pending += 1;
            }
        }
        return pending;
    }
#elif defined(__APPLE__)
    {
        size_t pending = 0;
        tr_async *cursor;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.0, 1);
        for (cursor = client->async_head; cursor; cursor = cursor->next) {
            if (cursor->status == TR_IN_PROGRESS) {
                if (cursor->has_deadline && CFAbsoluteTimeGetCurrent() >= cursor->deadline) {
                    tr__apple_set_error(cursor, TR_ERROR_BACKEND, "request timed out");
                    tr__apple_close_stream(cursor);
                } else {
                    tr__apple_read_available(cursor);
                }
            }
            if (cursor->status == TR_IN_PROGRESS) {
                pending += 1;
            }
        }
        return pending;
    }
#else
    {
        int running = 0;
        int queued = 0;
        tr_curl_msg *msg;
        size_t pending = 0;
        client->curl.multi_perform(client->curl_multi, &running);
        while ((msg = client->curl.multi_info_read(client->curl_multi, &queued)) != NULL) {
            if (msg->msg == TR__CURLMSG_DONE) {
                tr_async *async_request = NULL;
                long status_code = 0;
                async_request = tr__curl_find_async_by_easy(client, msg->easy_handle);
                if (!async_request) {
                    continue;
                }
                async_request->finished = 1;
                async_request->added_to_multi = 0;
                client->curl.multi_remove_handle(client->curl_multi, msg->easy_handle);
                client->curl.easy_getinfo(msg->easy_handle, TR__CURLINFO_RESPONSE_CODE, &status_code);
                async_request->response.status_code = status_code;
                if (msg->data.result == 0 && async_request->result_code != TR_ERROR_NOMEM) {
                    async_request->status = TR_OK;
                    async_request->result_code = TR_OK;
                    async_request->response.result_code = TR_OK;
                } else if (async_request->result_code == TR_ERROR_NOMEM) {
                    async_request->status = TR_ERROR_NOMEM;
                    async_request->response.result_code = TR_ERROR_NOMEM;
                    snprintf(async_request->response.error, sizeof(async_request->response.error), "%s", "out of memory");
                } else {
                    const char *err = client->curl.easy_strerror ? client->curl.easy_strerror(msg->data.result) : "curl async request failed";
                    if (strstr(err, "Timeout") != NULL) {
                        async_request->status = TR_ERROR_TIMEOUT;
                        async_request->result_code = TR_ERROR_TIMEOUT;
                        async_request->response.result_code = TR_ERROR_TIMEOUT;
                        snprintf(async_request->response.error, sizeof(async_request->response.error), "%s: timeout", "libcurl");
                    } else {
                        async_request->status = TR_ERROR_BACKEND;
                        async_request->result_code = TR_ERROR_BACKEND;
                        async_request->response.result_code = TR_ERROR_BACKEND;
                        snprintf(async_request->response.error, sizeof(async_request->response.error), "%s: %s", "libcurl", err);
                    }
                }
            }
        }
        for (tr_async *cursor = client->async_head; cursor; cursor = cursor->next) {
            if (cursor->status == TR_IN_PROGRESS) {
                pending += 1;
            }
        }
        return pending;
    }
#endif
}

int tr_async_status(const tr_async *async_request) {
    if (!async_request) {
        return TR_ERROR_INVALID_ARGUMENT;
    }
    return async_request->status;
}

int tr_async_take_response(tr_async *async_request, tr_response *out_response) {
    if (!async_request || !out_response) {
        return TR_ERROR_INVALID_ARGUMENT;
    }
    if (async_request->status == TR_IN_PROGRESS) {
        return TR_IN_PROGRESS;
    }
    *out_response = async_request->response;
    tr__response_reset(&async_request->response);
    async_request->status = TR_ERROR_STATE;
    return async_request->result_code;
}

int tr_async_poll(tr_client *client, tr_async *async_request, tr_response *out_response) {
    if (!client || !async_request) {
        return TR_ERROR_INVALID_ARGUMENT;
    }
    tr_client_poll(client);
    if (async_request->status == TR_IN_PROGRESS) {
        return TR_IN_PROGRESS;
    }
    if (!out_response) {
        return async_request->result_code;
    }
    return tr_async_take_response(async_request, out_response);
}

void tr_async_destroy(tr_async *async_request) {
    if (!async_request) {
        return;
    }
#ifdef _WIN32
    tr__unlink_async(async_request->client, async_request);
    tr__winhttp_destroy_async(async_request);
#elif defined(__APPLE__)
    tr__unlink_async(async_request->client, async_request);
    tr__apple_destroy_async(async_request);
#else
    tr__unlink_async(async_request->client, async_request);
    tr__curl_destroy_async(async_request);
#endif
}

#endif

#ifdef __cplusplus
}
#endif

#endif
