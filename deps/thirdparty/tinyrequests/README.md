# tinyrequests

`tinyrequests` is a tiny single-header C library for basic HTTP(S) requests.

- Windows uses the native `WinHTTP` API.
- macOS uses native `CFNetwork`/`CoreFoundation` APIs.
- Linux and BSD use `libcurl`, loaded at runtime on a best-effort basis.
- Async requests are polling-based and do not create threads in the library.

On Windows, async requests use WinHTTP async callbacks internally while the public API stays poll-driven.

## Status

This first cut is intentionally small.

- Windows sync and async requests work through `WinHTTP`.
- macOS sync and async requests work through `CFNetwork`.
- Linux and BSD sync and async requests work on the `libcurl` backend.
- Response headers are exposed through `tr_response.headers` and `tr_response.header_count`.

## Usage

In one C or C++ file:

```c
#define TINYREQUESTS_IMPLEMENTATION
#include "tinyrequests.h"
```

Example sync request:

```c
tr_client *client = tr_client_create(NULL);

tr_request req = {
    .method = "GET",
    .url = "https://example.com/",
};

tr_response res = {0};
int rc = tr_request_perform(client, &req, &res);
if (rc == TR_OK) {
    /* use res.status_code, res.headers, res.header_count, res.body, res.body_size */
}

tr_response_cleanup(&res);
tr_client_destroy(client);
```

The repository also includes runnable examples:

- `examples/sync_get.c`
- `examples/async_post.c`

Example async request:

```c
tr_client *client = tr_client_create(NULL);
tr_async *op = NULL;

tr_request req = {
    .method = "POST",
    .url = "https://httpbin.org/post",
    .body = "hello",
    .body_size = 5,
};

if (tr_request_begin(client, &req, &op) == TR_OK) {
    tr_response res = {0};
    while (tr_async_poll(client, op, &res) == TR_IN_PROGRESS) {
        /* your app loop */
    }
    tr_response_cleanup(&res);
    tr_async_destroy(op);
}

tr_client_destroy(client);
```

## Runtime `libcurl` loading

On Linux and BSD the library tries a few common names such as `libcurl.so`, `libcurl.so.4`, and `libcurl.dylib`.

You can override that by passing a `tr_config`:

```c
tr_config cfg = {
    .curl_library_path = "/custom/path/libcurl.so",
};

tr_client *client = tr_client_create(&cfg);
```

You can also provide your own `dlopen` result or a full function table through `tr_config.curl_library_handle` or `tr_config.curl_vtable`.

## Build notes

- Windows: link against `winhttp.lib`.
- Linux/BSD: link against `libdl` if needed by your toolchain.
- macOS: link `CoreFoundation` and `CFNetwork`.

## Makefile

Build the examples with:

```sh
make
```

Run them with:

```sh
./examples/sync_get
./examples/async_post
```

On Windows with MinGW, run:

```sh
examples\sync_get.exe
examples\async_post.exe
```

## API summary

- `tr_client_create`, `tr_client_destroy`
- `tr_request_perform`
- `tr_request_begin`, `tr_client_poll`, `tr_async_poll`, `tr_async_take_response`, `tr_async_destroy`
- `tr_response_cleanup`

## Response headers

Each `tr_response` owns an array of response headers:

```c
for (size_t i = 0; i < response.header_count; ++i) {
    printf("%s: %s\n", response.headers[i].name, response.headers[i].value);
}
```

These strings are freed by `tr_response_cleanup()`.

## Errors and timeouts

- `TR_ERROR_TIMEOUT` is returned for request timeouts on all backends.
- `tr_response.error` uses normalized backend-prefixed messages such as `winhttp: timeout` or `libcurl: <detail>`.
- `timeout_ms <= 0` means no explicit timeout is configured by `tinyrequests` for that request.
