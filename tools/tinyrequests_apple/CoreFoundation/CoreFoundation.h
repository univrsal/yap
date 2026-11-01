/* A stand-in for the parts of CoreFoundation that tinyrequests uses, to compile
   and test its Apple code on another system. Only declarations; the test defines
   what it needs. */
#ifndef FAKE_CF_H
#define FAKE_CF_H
#include <stddef.h>
#include <errno.h>
typedef unsigned char Boolean;
typedef unsigned char UInt8;
typedef int SInt32;
typedef unsigned int UInt32;
typedef long CFIndex;
typedef unsigned long CFTypeID;
typedef double CFAbsoluteTime;
typedef const void *CFTypeRef;
typedef const struct __CFString *CFStringRef;
typedef const struct __CFURL *CFURLRef;
typedef const struct __CFDictionary *CFDictionaryRef;
typedef struct __CFReadStream *CFReadStreamRef;
typedef struct __CFRunLoop *CFRunLoopRef;
typedef const struct __CFAllocator *CFAllocatorRef;
typedef const struct __CFBoolean *CFBooleanRef;
typedef const struct __CFData *CFDataRef;
typedef struct __CFHTTPMessage *CFHTTPMessageRef;
typedef CFStringRef CFRunLoopMode;
typedef unsigned long CFStreamEventType;
typedef unsigned long CFStringEncoding;
typedef CFStringRef CFStreamPropertyKey;
typedef struct { CFIndex domain; SInt32 error; } CFStreamError;
typedef enum { kCFStreamStatusNotOpen = 0, kCFStreamStatusOpening, kCFStreamStatusOpen, kCFStreamStatusReading, kCFStreamStatusWriting, kCFStreamStatusAtEnd, kCFStreamStatusClosed, kCFStreamStatusError } CFStreamStatus;
enum { kCFStreamErrorDomainCustom = -1, kCFStreamErrorDomainPOSIX = 1, kCFStreamErrorDomainMacOSStatus };
typedef struct { CFIndex version; void *info; void *(*retain)(void *); void (*release)(void *); CFStringRef (*copyDescription)(void *); } CFStreamClientContext;
typedef void (*CFReadStreamClientCallBack)(CFReadStreamRef, CFStreamEventType, void *);
typedef void (*CFDictionaryApplierFunction)(const void *key, const void *value, void *context);
typedef struct { CFIndex location; CFIndex length; } CFRange;
#define kCFStreamEventNone 0
#define kCFStreamEventOpenCompleted 1
#define kCFStreamEventHasBytesAvailable 2
#define kCFStreamEventErrorOccurred 8
#define kCFStreamEventEndEncountered 16
#define kCFStringEncodingUTF8 0x08000100
#define kCFHTTPVersion1_1 NULL
extern const CFAllocatorRef kCFAllocatorDefault;
extern const CFBooleanRef kCFBooleanTrue;
extern const CFRunLoopMode kCFRunLoopDefaultMode;
extern const CFStreamPropertyKey kCFStreamPropertyHTTPResponseHeader, kCFStreamPropertyHTTPShouldAutoredirect;
extern CFStringRef kCFStreamPropertyHTTPAttemptPersistentConnection;
CFTypeID CFGetTypeID(CFTypeRef);
CFTypeID CFStringGetTypeID(void);
void CFRelease(CFTypeRef);
CFTypeRef CFRetain(CFTypeRef);
CFStringRef CFStringCreateWithCString(CFAllocatorRef, const char *, CFStringEncoding);
CFIndex CFStringGetLength(CFStringRef);
CFIndex CFStringGetMaximumSizeForEncoding(CFIndex, CFStringEncoding);
Boolean CFStringGetCString(CFStringRef, char *, CFIndex, CFStringEncoding);
CFURLRef CFURLCreateWithString(CFAllocatorRef, CFStringRef, CFURLRef);
CFDataRef CFDataCreate(CFAllocatorRef, const UInt8 *, CFIndex);
CFReadStreamRef CFReadStreamCreateForHTTPRequest(CFAllocatorRef, CFHTTPMessageRef);
CFTypeRef CFReadStreamCopyProperty(CFReadStreamRef, CFStreamPropertyKey);
Boolean CFReadStreamSetProperty(CFReadStreamRef, CFStreamPropertyKey, CFTypeRef);
Boolean CFReadStreamSetClient(CFReadStreamRef, CFStreamEventType, CFReadStreamClientCallBack, CFStreamClientContext *);
void CFReadStreamScheduleWithRunLoop(CFReadStreamRef, CFRunLoopRef, CFRunLoopMode);
void CFReadStreamUnscheduleFromRunLoop(CFReadStreamRef, CFRunLoopRef, CFRunLoopMode);
Boolean CFReadStreamOpen(CFReadStreamRef);
void CFReadStreamClose(CFReadStreamRef);
CFIndex CFReadStreamRead(CFReadStreamRef, UInt8 *, CFIndex);
Boolean CFReadStreamHasBytesAvailable(CFReadStreamRef);
CFStreamError CFReadStreamGetError(CFReadStreamRef);
CFStreamStatus CFReadStreamGetStatus(CFReadStreamRef);
CFRunLoopRef CFRunLoopGetCurrent(void);
int CFRunLoopRunInMode(CFRunLoopMode, double, Boolean);
void CFRunLoopStop(CFRunLoopRef);
CFAbsoluteTime CFAbsoluteTimeGetCurrent(void);
CFTypeID CFHTTPMessageGetTypeID(void);
CFHTTPMessageRef CFHTTPMessageCreateRequest(CFAllocatorRef, CFStringRef, CFURLRef, CFStringRef);
void CFHTTPMessageSetHeaderFieldValue(CFHTTPMessageRef, CFStringRef, CFStringRef);
void CFHTTPMessageSetBody(CFHTTPMessageRef, CFDataRef);
CFDictionaryRef CFHTTPMessageCopyAllHeaderFields(CFHTTPMessageRef);
CFIndex CFHTTPMessageGetResponseStatusCode(CFHTTPMessageRef);
void CFDictionaryApplyFunction(CFDictionaryRef, CFDictionaryApplierFunction, void *);
CFIndex CFDictionaryGetCount(CFDictionaryRef);
#endif
