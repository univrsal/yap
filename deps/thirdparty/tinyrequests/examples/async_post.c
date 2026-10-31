#include <stdio.h>

#define TINYREQUESTS_IMPLEMENTATION
#include "../tinyrequests.h"

int main(void) {
    static const char payload[] = "hello from tinyrequests";
    static const tr_header headers[] = {
        { "content-type", "text/plain" }
    };
    tr_client *client;
    tr_request request;
    tr_async *async_request = NULL;
    tr_response response = {0};
    int rc;

    client = tr_client_create(NULL);
    if (!client) {
        fprintf(stderr, "failed to create client\n");
        return 1;
    }

    request.method = "POST";
    request.url = "https://httpbin.org/post";
    request.headers = headers;
    request.header_count = sizeof(headers) / sizeof(headers[0]);
    request.body = payload;
    request.body_size = sizeof(payload) - 1;
    request.timeout_ms = 10000;

    rc = tr_request_begin(client, &request, &async_request);
    if (rc == TR_ERROR_UNSUPPORTED) {
        fprintf(stderr, "async is not implemented for backend: %s\n", tr_client_backend_name(client));
        tr_client_destroy(client);
        return 2;
    }
    if (rc != TR_OK) {
        fprintf(stderr, "failed to begin request\n");
        tr_client_destroy(client);
        return 1;
    }

    while ((rc = tr_async_poll(client, async_request, &response)) == TR_IN_PROGRESS) {
        /* app-driven polling loop */
    }

    if (rc != TR_OK) {
        fprintf(stderr, "async request failed: %s\n", response.error[0] ? response.error : "unknown error");
        tr_response_cleanup(&response);
        tr_async_destroy(async_request);
        tr_client_destroy(client);
        return 1;
    }

    printf("backend: %s\n", tr_client_backend_name(client));
    printf("status: %ld\n", response.status_code);
    printf("bytes: %lu\n", (unsigned long) response.body_size);
    printf("headers: %lu\n", (unsigned long) response.header_count);
    if (response.header_count > 0) {
        printf("first-header: %s: %s\n", response.headers[0].name, response.headers[0].value);
    }
    if (response.body && response.body_size) {
        size_t preview = response.body_size < 200 ? response.body_size : 200;
        fwrite(response.body, 1, preview, stdout);
        if (preview < response.body_size) {
            printf("\n...\n");
        } else {
            printf("\n");
        }
    }

    tr_response_cleanup(&response);
    tr_async_destroy(async_request);
    tr_client_destroy(client);
    return 0;
}
