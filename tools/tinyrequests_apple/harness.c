/*
 * Drives tinyrequests' CFNetwork code (deps/thirdparty/tinyrequests), compiled as if
 * on a Mac against a stand-in for CoreFoundation (CoreFoundation/CoreFoundation.h
 * here: declarations only), with a scripted fake stream. It is for what can't be run
 * on any other system: reading an answer in the poll loop, the stream's callbacks
 * running during a read, and the size cap. Run it with run.sh.
 *
 * It found two bugs that the tests on a Mac then showed: the headers were not
 * captured when the poll loop read the whole answer, and a callback that failed the
 * request (the answer too large) had its error overwritten with "read failed".
 */
#define TINYREQUESTS_IMPLEMENTATION
#include "tinyrequests.h"
#include <stdio.h>

/* ---- the fake CoreFoundation ---- */
const CFAllocatorRef kCFAllocatorDefault = 0;
const CFBooleanRef kCFBooleanTrue = 0;
const CFRunLoopMode kCFRunLoopDefaultMode = 0;
const CFStreamPropertyKey kCFStreamPropertyHTTPResponseHeader = 0, kCFStreamPropertyHTTPShouldAutoredirect = 0;
CFStringRef kCFStreamPropertyHTTPAttemptPersistentConnection = 0;

typedef struct { const char *text; } FakeString;
static int g_string_type, g_message_type;
static const void *MESSAGE = &g_message_type;
CFTypeID CFGetTypeID(CFTypeRef r) { return r == MESSAGE ? 2 : 1; }
CFTypeID CFStringGetTypeID(void) { return 1; }
CFTypeID CFHTTPMessageGetTypeID(void) { return 2; }
void CFRelease(CFTypeRef r) { (void)r; }
CFIndex CFStringGetLength(CFStringRef s) { return (CFIndex)strlen(((const FakeString *)s)->text); }
CFIndex CFStringGetMaximumSizeForEncoding(CFIndex n, CFStringEncoding e) { (void)e; return n * 4; }
Boolean CFStringGetCString(CFStringRef s, char *buf, CFIndex size, CFStringEncoding e) { (void)e; strncpy(buf, ((const FakeString *)s)->text, (size_t)size); return 1; }
static FakeString H_NAME_TYPE = {"Content-Type"}, H_TYPE = {"text/plain"}, H_NAME_MULTI = {"X-Multi"}, H_MULTI = {"1, 2"};
CFDictionaryRef CFHTTPMessageCopyAllHeaderFields(CFHTTPMessageRef m) { (void)m; return (CFDictionaryRef)&g_string_type; }
void CFDictionaryApplyFunction(CFDictionaryRef d, CFDictionaryApplierFunction f, void *ctx) {
    (void)d; f(&H_NAME_TYPE, &H_TYPE, ctx); f(&H_NAME_MULTI, &H_MULTI, ctx);
}
CFIndex CFHTTPMessageGetResponseStatusCode(CFHTTPMessageRef m) { (void)m; return 200; }
CFTypeRef CFReadStreamCopyProperty(CFReadStreamRef s, CFStreamPropertyKey k) { (void)s; (void)k; return MESSAGE; }
static CFStreamError g_error = {1, 54};
CFStreamError CFReadStreamGetError(CFReadStreamRef s) { (void)s; return g_error; }

/* the scripted stream */
static size_t g_total, g_pos;      /* the answer's size, and how much has been read */
static int g_closed;
static size_t g_reenter_at;        /* run the stream's callback while reading at this position (0: never) */
static tr_async *g_async;
static int g_reentered;
static int g_reads;                /* calls of CFReadStreamRead */
static int g_stalled;              /* the server has sent nothing (yet): no bytes are available */
static int g_failed;               /* the stream is in an error state */
CFStreamStatus CFReadStreamGetStatus(CFReadStreamRef s) {
    (void)s;
    if (g_failed) return kCFStreamStatusError;
    if (g_closed) return kCFStreamStatusClosed;
    if (!g_stalled && g_pos >= g_total) return kCFStreamStatusAtEnd;
    return kCFStreamStatusOpen;
}
Boolean CFReadStreamHasBytesAvailable(CFReadStreamRef s) { (void)s; return !g_stalled && !g_closed && g_pos < g_total; }
void CFReadStreamClose(CFReadStreamRef s) { (void)s; g_closed = 1; }
CFIndex CFReadStreamRead(CFReadStreamRef s, UInt8 *buf, CFIndex len) {
    g_reads++;
    if (g_stalled) { printf("  (a read with nothing to read: it would block)\n"); return -1; }
    if (g_reenter_at && !g_reentered && g_pos >= g_reenter_at) {
        g_reentered = 1;
        tr__apple_stream_cb(s, kCFStreamEventHasBytesAvailable, g_async); /* what a run loop does */
    }
    if (g_closed) return -1;
    if (g_pos >= g_total) return 0;
    size_t n = g_total - g_pos < (size_t)len ? g_total - g_pos : (size_t)len;
    memset(buf, 'x', n);
    g_pos += n;
    return (CFIndex)n;
}


/* never reached by the harness; here so that it links */
CFStringRef CFStringCreateWithCString(CFAllocatorRef a, const char *c, CFStringEncoding e) { (void)a; (void)c; (void)e; return 0; }
void CFHTTPMessageSetHeaderFieldValue(CFHTTPMessageRef m, CFStringRef a, CFStringRef b) { (void)m; (void)a; (void)b; }
CFDataRef CFDataCreate(CFAllocatorRef a, const UInt8 *p, CFIndex n) { (void)a; (void)p; (void)n; return 0; }
void CFHTTPMessageSetBody(CFHTTPMessageRef m, CFDataRef d) { (void)m; (void)d; }
CFURLRef CFURLCreateWithString(CFAllocatorRef a, CFStringRef s, CFURLRef u) { (void)a; (void)s; (void)u; return 0; }
CFHTTPMessageRef CFHTTPMessageCreateRequest(CFAllocatorRef a, CFStringRef m, CFURLRef u, CFStringRef v) { (void)a; (void)m; (void)u; (void)v; return 0; }
Boolean CFReadStreamSetClient(CFReadStreamRef s, CFStreamEventType t, CFReadStreamClientCallBack c, CFStreamClientContext *x) { (void)s; (void)t; (void)c; (void)x; return 0; }
void CFReadStreamUnscheduleFromRunLoop(CFReadStreamRef s, CFRunLoopRef r, CFRunLoopMode m) { (void)s; (void)r; (void)m; }
CFReadStreamRef CFReadStreamCreateForHTTPRequest(CFAllocatorRef a, CFHTTPMessageRef m) { (void)a; (void)m; return 0; }
Boolean CFReadStreamSetProperty(CFReadStreamRef s, CFStreamPropertyKey k, CFTypeRef v) { (void)s; (void)k; (void)v; return 0; }
CFRunLoopRef CFRunLoopGetCurrent(void) { return 0; }
CFTypeRef CFRetain(CFTypeRef r) { return r; }
CFAbsoluteTime CFAbsoluteTimeGetCurrent(void) { return 0; }
void CFReadStreamScheduleWithRunLoop(CFReadStreamRef s, CFRunLoopRef r, CFRunLoopMode m) { (void)s; (void)r; (void)m; }
Boolean CFReadStreamOpen(CFReadStreamRef s) { (void)s; return 0; }
int CFRunLoopRunInMode(CFRunLoopMode m, double t, Boolean b) { (void)m; (void)t; (void)b; return 0; }

static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("  FAIL: " __VA_ARGS__); printf("\n"); } } while (0)

static void run(const char *name, size_t total, size_t cap, size_t reenter_at, int expect_status, int expect_headers) {
    g_stalled = g_failed = g_reads = 0;
    g_error = (CFStreamError){1, 54};
    tr_config cfg; memset(&cfg, 0, sizeof cfg);
    cfg.max_response_size = cap;
    tr_client *client = tr_client_create(&cfg);
    tr_async a; memset(&a, 0, sizeof a);
    a.client = client; a.status = TR_IN_PROGRESS; a.result_code = TR_IN_PROGRESS;
    a.stream = (CFReadStreamRef)&a;
    tr__response_reset(&a.response);
    g_async = &a; g_total = total; g_pos = 0; g_closed = 0; g_reenter_at = reenter_at; g_reentered = 0;

    tr__apple_read_available(&a);   /* what tr_client_poll does for a request in progress */

    int has_type = 0;
    for (size_t i = 0; i < a.response.header_count; i++) if (!strcasecmp(a.response.headers[i].name, "content-type")) has_type = 1;
    printf("%-44s status=%d body=%zu headers=%zu error=\"%s\"\n", name, a.status, a.response.body_size, a.response.header_count, a.response.error);
    CHECK(a.status == expect_status, "status %d, wanted %d", a.status, expect_status);
    if (expect_headers >= 0) CHECK(has_type == expect_headers, "content-type %s", has_type ? "present" : "missing");
    tr_response_cleanup(&a.response);
    tr_client_destroy(client);
}

int main(void) {
    printf("-- a small answer, read in one go (no callback ran first)\n");
    run("small", 21, 1 << 20, 0, TR_OK, 1);
    printf("-- an answer over the cap, plain\n");
    run("big", 3 << 20, 1 << 20, 0, TR_ERROR_NOMEM, 0);
    printf("-- an answer over the cap, with the stream's callback running during a read\n");
    run("big, callback during a read", 3 << 20, 1 << 20, (1 << 20) - 8192, TR_ERROR_NOMEM, -1);
    printf("-- an answer under the cap, with a callback during a read\n");
    run("under the cap, callback during a read", 600 * 1024, 1 << 20, 100 * 1024, TR_OK, 1);
    printf("-- nothing to read yet (a slow server): it must not read, and must not finish\n");
    {
        tr_config cfg; memset(&cfg, 0, sizeof cfg);
        tr_client *client = tr_client_create(&cfg);
        tr_async a; memset(&a, 0, sizeof a);
        a.client = client; a.status = TR_IN_PROGRESS; a.result_code = TR_IN_PROGRESS;
        a.stream = (CFReadStreamRef)&a; tr__response_reset(&a.response);
        g_async = &a; g_total = 100; g_pos = 0; g_closed = 0; g_reenter_at = 0; g_reentered = 0; g_failed = 0; g_reads = 0;
        g_stalled = 1;
        tr__apple_read_available(&a);
        tr__apple_read_available(&a);
        printf("stalled                                      status=%d reads=%d\n", a.status, g_reads);
        CHECK(g_reads == 0, "it read %d time(s) with nothing to read", g_reads);
        CHECK(a.status == TR_IN_PROGRESS, "status %d, wanted in progress", a.status);
        g_stalled = 0; /* the data comes */
        tr__apple_read_available(&a);
        CHECK(a.status == TR_OK && a.response.body_size == 100, "after the data came: status %d, %zu bytes", a.status, a.response.body_size);
        tr_response_cleanup(&a.response);
        tr_client_destroy(client);
    }
    printf("-- the stream failed: a refused connection says so; a timeout is a timeout\n");
    {
        tr_config cfg; memset(&cfg, 0, sizeof cfg);
        tr_client *client = tr_client_create(&cfg);
        for (int k = 0; k < 3; k++) {
            tr_async a; memset(&a, 0, sizeof a);
            a.client = client; a.status = TR_IN_PROGRESS; a.result_code = TR_IN_PROGRESS;
            a.stream = (CFReadStreamRef)&a; tr__response_reset(&a.response);
            g_async = &a; g_total = 100; g_pos = 0; g_closed = 0; g_reenter_at = 0; g_reentered = 0; g_stalled = 0; g_reads = 0;
            g_failed = 1;
            g_error = k == 0 ? (CFStreamError){kCFStreamErrorDomainPOSIX, ECONNREFUSED} : k == 1 ? (CFStreamError){kCFStreamErrorDomainPOSIX, ETIMEDOUT} : (CFStreamError){4, -4};
            tr__apple_read_available(&a);
            printf("failed (%ld, %d)                              status=%d error=\"%s\"\n", (long)g_error.domain, (int)g_error.error, a.status, a.response.error);
            CHECK(g_reads == 0, "read a failed stream");
            CHECK(a.status == (k == 1 ? TR_ERROR_TIMEOUT : TR_ERROR_BACKEND), "status %d", a.status);
            if (k == 0) CHECK(strstr(a.response.error, "refused") != NULL, "error \"%s\"", a.response.error);
            if (k == 2) CHECK(strstr(a.response.error, "domain 4, code -4") != NULL, "error \"%s\"", a.response.error);
            tr_response_cleanup(&a.response);
        }
        tr_client_destroy(client);
    }
    printf("%s\n", failures ? "FAILED" : "all as wanted");
    return failures != 0;
}
