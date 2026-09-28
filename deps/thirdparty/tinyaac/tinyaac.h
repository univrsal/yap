/*
 * tinyaac.h - generated single-header application audio capture API
 * DO NOT EDIT: run tools/generate_header.py after changing src fragments.
 * Public-domain / MIT dual-licensed. See LICENSE or UNLICENSE.
 */
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE 1
#endif

/* Begin tinyaac_public.h */
/*
 * tinyaac.h - tiny application audio capture library
 *
 * Public-domain / MIT dual-licensed. See LICENSE or UNLICENSE.
 */
#ifndef TINYAAC_PUBLIC_H_INCLUDED
#define TINYAAC_PUBLIC_H_INCLUDED

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef TINYAAC_API
#define TINYAAC_API extern
#endif

#define TINYAAC_VERSION_MAJOR 0
#define TINYAAC_VERSION_MINOR 1
#define TINYAAC_VERSION_PATCH 0

/* Define TINYAAC_IMPLEMENTATION in exactly one translation unit. On macOS,
 * that translation unit must be compiled as Objective-C (.m). */

typedef struct tinyaac_app_list tinyaac_app_list;
typedef struct tinyaac_capture tinyaac_capture;

typedef enum tinyaac_status {
	TINYAAC_OK = 0,
	TINYAAC_ERR_INVALID_ARGUMENT = -1,
	TINYAAC_ERR_INVALID_STATE = -2,
	TINYAAC_ERR_OUT_OF_MEMORY = -3,
	TINYAAC_ERR_PLATFORM_UNAVAILABLE = -4,
	TINYAAC_ERR_PERMISSION_DENIED = -5,
	TINYAAC_ERR_NOT_FOUND = -6,
	TINYAAC_ERR_BACKEND = -7,
	TINYAAC_ERR_UNSUPPORTED_FORMAT = -8
} tinyaac_status;

typedef enum tinyaac_event {
	TINYAAC_EVENT_STARTED,
	TINYAAC_EVENT_STOPPED,
	TINYAAC_EVENT_TARGET_ENDED,
	TINYAAC_EVENT_BACKEND_ERROR
} tinyaac_event;

typedef struct tinyaac_app_info {
	/* These strings are owned by the app-list and remain valid until it is
	 * destroyed. An index is valid only for its originating app-list. */
	const char *display_name;
	const char *identifier;
	/* Native process ID when the backend exposes one; otherwise zero. */
	uint32_t process_id;
} tinyaac_app_info;

typedef struct tinyaac_audio_frame {
	/* Interleaved IEEE-754 float32 PCM in the range [-1.0, 1.0]. The memory
	 * is owned by tinyaac and is valid only for the callback duration. */
	const float *samples;
	size_t frame_count;
	uint32_t channels;
	uint32_t sample_rate;
	uint64_t timestamp_ns;
} tinyaac_audio_frame;

typedef void (*tinyaac_audio_callback)(const tinyaac_audio_frame *frame,
		void *user_data);
typedef void (*tinyaac_event_callback)(tinyaac_event event,
		tinyaac_status status, const char *message, void *user_data);

/* Initializes process-wide backend state. This function is reference counted;
 * pair each successful call with tinyaac_shutdown(). */
TINYAAC_API tinyaac_status tinyaac_init(void);
TINYAAC_API void tinyaac_shutdown(void);
TINYAAC_API const char *tinyaac_last_error(void);

/* Lists applications currently producing audio. The returned snapshot is
 * immutable and must be destroyed with tinyaac_app_list_destroy(). */
TINYAAC_API tinyaac_status tinyaac_app_list_create(tinyaac_app_list **out_list);
TINYAAC_API size_t tinyaac_app_list_count(const tinyaac_app_list *list);
TINYAAC_API const tinyaac_app_info *tinyaac_app_list_get(
	const tinyaac_app_list *list, size_t index);
TINYAAC_API void tinyaac_app_list_destroy(tinyaac_app_list *list);

/* Creates one capture from an app-list index. The capture retains the target
 * identity, so the list may be destroyed after this call returns. */
TINYAAC_API tinyaac_status tinyaac_capture_create(const tinyaac_app_list *list,
	size_t index, tinyaac_capture **out_capture);
TINYAAC_API tinyaac_status tinyaac_capture_set_callbacks(tinyaac_capture *capture,
	tinyaac_audio_callback on_audio, tinyaac_event_callback on_event,
	void *user_data);
TINYAAC_API tinyaac_status tinyaac_capture_start(tinyaac_capture *capture);
/* Blocks until all in-flight callbacks have returned. */
TINYAAC_API tinyaac_status tinyaac_capture_stop(tinyaac_capture *capture);
TINYAAC_API void tinyaac_capture_destroy(tinyaac_capture *capture);

#ifdef __cplusplus
}
#endif

#endif /* TINYAAC_PUBLIC_H_INCLUDED */
/* End tinyaac_public.h */

#ifdef TINYAAC_IMPLEMENTATION

/* Begin tinyaac_internal.h */
#ifndef TINYAAC_INTERNAL_H_INCLUDED
#define TINYAAC_INTERNAL_H_INCLUDED

#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#if defined(__GNUC__) || defined(__clang__)
#define TINYAAC_INTERNAL_UNUSED __attribute__((unused))
#else
#define TINYAAC_INTERNAL_UNUSED
#endif

struct tinyaac_app_list {
	size_t count;
	size_t capacity;
	tinyaac_app_info *apps;
};

struct tinyaac_capture {
	char *identifier;
	uint32_t process_id;
	tinyaac_audio_callback on_audio;
	tinyaac_event_callback on_event;
	void *user_data;
	void *backend;
	int started;
};

static void tinyaac_internal_set_error(const char *message);
static tinyaac_status tinyaac_platform_init(void);
static void tinyaac_platform_shutdown(void);
static tinyaac_status tinyaac_platform_enumerate(tinyaac_app_list *list);
static tinyaac_status tinyaac_platform_capture_start(tinyaac_capture *capture);
static tinyaac_status tinyaac_platform_capture_stop(tinyaac_capture *capture);
static void tinyaac_platform_capture_destroy(tinyaac_capture *capture);

static char *tinyaac_internal_strdup(const char *value)
{
	size_t size;
	char *copy;

	if (!value)
		return NULL;
	size = strlen(value) + 1;
	copy = (char *)malloc(size);
	if (copy)
		memcpy(copy, value, size);
	return copy;
}

static TINYAAC_INTERNAL_UNUSED tinyaac_status tinyaac_internal_append_app(tinyaac_app_list *list,
	const char *display_name, const char *identifier, uint32_t process_id)
{
	tinyaac_app_info *apps;
	char *name_copy;
	char *identifier_copy;

	if (!list || !display_name || !identifier)
		return TINYAAC_ERR_INVALID_ARGUMENT;
	if (list->count == list->capacity) {
		size_t capacity = list->capacity ? list->capacity * 2 : 8;
		apps = (tinyaac_app_info *)realloc(list->apps, capacity * sizeof(*apps));
		if (!apps)
			return TINYAAC_ERR_OUT_OF_MEMORY;
		list->apps = apps;
		list->capacity = capacity;
	}
	name_copy = tinyaac_internal_strdup(display_name);
	identifier_copy = tinyaac_internal_strdup(identifier);
	if (!name_copy || !identifier_copy) {
		free(name_copy);
		free(identifier_copy);
		return TINYAAC_ERR_OUT_OF_MEMORY;
	}
	list->apps[list->count].display_name = name_copy;
	list->apps[list->count].identifier = identifier_copy;
	list->apps[list->count].process_id = process_id;
	list->count++;
	return TINYAAC_OK;
}

#endif /* TINYAAC_INTERNAL_H_INCLUDED */
/* End tinyaac_internal.h */

/* Begin tinyaac_win.h */
/* Windows WASAPI process-loopback backend. */
#ifdef _WIN32

#ifndef COBJMACROS
#define COBJMACROS
#endif
#ifndef CINTERFACE
#define CINTERFACE
#endif
#include <windows.h>
#include <audioclient.h>
#include <audioclientactivationparams.h>
#include <ksmedia.h>
#include <mmdeviceapi.h>

#ifdef __cplusplus
#define TINYAAC_WIN_REFIID(value) value
#else
#define TINYAAC_WIN_REFIID(value) &(value)
#endif

typedef HRESULT (WINAPI *tinyaac_activate_audio_interface_async_fn)(
	LPCWSTR, REFIID, const PROPVARIANT *, IActivateAudioInterfaceCompletionHandler *,
	IActivateAudioInterfaceAsyncOperation **);

struct tinyaac_win_work {
	struct tinyaac_win_work *next;
	int is_event;
	tinyaac_audio_frame frame;
	tinyaac_event event;
	tinyaac_status status;
	char message[128];
	float samples[1];
};

struct tinyaac_win_capture {
	DWORD process_id;
	HANDLE capture_thread;
	HANDLE callback_thread;
	HANDLE stop_event;
	HANDLE ready_event;
	HANDLE audio_event;
	HANDLE process_handle;
	CRITICAL_SECTION queue_lock;
	CONDITION_VARIABLE queue_ready;
	struct tinyaac_win_work *queue_head;
	struct tinyaac_win_work *queue_tail;
	LONG closing;
	LONG callback_worker_started;
	HRESULT start_result;
};

struct tinyaac_win_activation_handler {
	IActivateAudioInterfaceCompletionHandler iface;
	LONG references;
	HANDLE completed_event;
	HRESULT result;
	IAudioClient *client;
};

static HRESULT STDMETHODCALLTYPE tinyaac_win_activation_query_interface(
	IActivateAudioInterfaceCompletionHandler *self, REFIID iid, void **out)
{
	if (!out)
		return E_POINTER;
	*out = NULL;
	if (IsEqualIID(iid, TINYAAC_WIN_REFIID(IID_IUnknown)) ||
		IsEqualIID(iid, TINYAAC_WIN_REFIID(IID_IActivateAudioInterfaceCompletionHandler))) {
		InterlockedIncrement(&((struct tinyaac_win_activation_handler *)self)->references);
		*out = self;
		return S_OK;
	}
	return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE tinyaac_win_activation_add_ref(
	IActivateAudioInterfaceCompletionHandler *self)
{
	return (ULONG)InterlockedIncrement(
		&((struct tinyaac_win_activation_handler *)self)->references);
}

static ULONG STDMETHODCALLTYPE tinyaac_win_activation_release(
	IActivateAudioInterfaceCompletionHandler *self)
{
	struct tinyaac_win_activation_handler *handler =
		(struct tinyaac_win_activation_handler *)self;
	LONG references = InterlockedDecrement(&handler->references);
	if (!references)
		free(handler);
	return (ULONG)references;
}

static HRESULT STDMETHODCALLTYPE tinyaac_win_activation_completed(
	IActivateAudioInterfaceCompletionHandler *self,
	IActivateAudioInterfaceAsyncOperation *operation)
{
	struct tinyaac_win_activation_handler *handler =
		(struct tinyaac_win_activation_handler *)self;
	IUnknown *unknown = NULL;
	HRESULT activation_result = E_FAIL;
	handler->result = IActivateAudioInterfaceAsyncOperation_GetActivateResult(operation,
		&activation_result, &unknown);
	if (SUCCEEDED(handler->result))
		handler->result = activation_result;
	if (SUCCEEDED(handler->result) && unknown)
		handler->result = IUnknown_QueryInterface(unknown, TINYAAC_WIN_REFIID(IID_IAudioClient),
			(void **)&handler->client);
	if (unknown)
		IUnknown_Release(unknown);
	SetEvent(handler->completed_event);
	return S_OK;
}

static const IActivateAudioInterfaceCompletionHandlerVtbl tinyaac_win_activation_vtbl = {
	tinyaac_win_activation_query_interface,
	tinyaac_win_activation_add_ref,
	tinyaac_win_activation_release,
	tinyaac_win_activation_completed,
};

static struct tinyaac_win_activation_handler *tinyaac_win_activation_handler_create(void)
{
	struct tinyaac_win_activation_handler *handler =
		(struct tinyaac_win_activation_handler *)calloc(1, sizeof(*handler));
	if (!handler)
		return NULL;
	handler->iface.lpVtbl = &tinyaac_win_activation_vtbl;
	handler->references = 1;
	handler->completed_event = CreateEventW(NULL, FALSE, FALSE, NULL);
	if (!handler->completed_event) {
		free(handler);
		return NULL;
	}
	return handler;
}

static void tinyaac_win_enqueue(struct tinyaac_win_capture *backend,
	struct tinyaac_win_work *work)
{
	EnterCriticalSection(&backend->queue_lock);
	if (InterlockedCompareExchange(&backend->closing, 0, 0)) {
		LeaveCriticalSection(&backend->queue_lock);
		free(work);
		return;
	}
	if (backend->queue_tail)
		backend->queue_tail->next = work;
	else
		backend->queue_head = work;
	backend->queue_tail = work;
	WakeConditionVariable(&backend->queue_ready);
	LeaveCriticalSection(&backend->queue_lock);
}

static void tinyaac_win_enqueue_event(struct tinyaac_win_capture *backend,
	tinyaac_event event, tinyaac_status status, const char *message)
{
	struct tinyaac_win_work *work =
		(struct tinyaac_win_work *)calloc(1, sizeof(*work));
	if (!work)
		return;
	work->is_event = 1;
	work->event = event;
	work->status = status;
	if (message)
		snprintf(work->message, sizeof(work->message), "%s", message);
	tinyaac_win_enqueue(backend, work);
}

static DWORD WINAPI tinyaac_win_callback_thread(void *data)
{
	tinyaac_capture *capture = (tinyaac_capture *)data;
	struct tinyaac_win_capture *backend =
		(struct tinyaac_win_capture *)capture->backend;
	for (;;) {
		struct tinyaac_win_work *work;
		EnterCriticalSection(&backend->queue_lock);
		while (!backend->queue_head && !InterlockedCompareExchange(&backend->closing, 0, 0))
			SleepConditionVariableCS(&backend->queue_ready, &backend->queue_lock, INFINITE);
		if (!backend->queue_head && InterlockedCompareExchange(&backend->closing, 0, 0)) {
			LeaveCriticalSection(&backend->queue_lock);
			break;
		}
		work = backend->queue_head;
		backend->queue_head = work->next;
		if (!backend->queue_head)
			backend->queue_tail = NULL;
		LeaveCriticalSection(&backend->queue_lock);
		if (work->is_event) {
			if (capture->on_event)
				capture->on_event(work->event, work->status, work->message, capture->user_data);
		} else if (capture->on_audio) {
			capture->on_audio(&work->frame, capture->user_data);
		}
		free(work);
	}
	return 0;
}

static int tinyaac_win_format_is_float(const WAVEFORMATEX *format)
{
	if (format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT)
		return 1;
	if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
		format->cbSize >= sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
		const WAVEFORMATEXTENSIBLE *extended = (const WAVEFORMATEXTENSIBLE *)format;
		return IsEqualGUID(TINYAAC_WIN_REFIID(extended->SubFormat),
			TINYAAC_WIN_REFIID(KSDATAFORMAT_SUBTYPE_IEEE_FLOAT));
	}
	return 0;
}

static int tinyaac_win_format_is_pcm(const WAVEFORMATEX *format)
{
	if (format->wFormatTag == WAVE_FORMAT_PCM)
		return 1;
	if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
		format->cbSize >= sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
		const WAVEFORMATEXTENSIBLE *extended = (const WAVEFORMATEXTENSIBLE *)format;
		return IsEqualGUID(TINYAAC_WIN_REFIID(extended->SubFormat),
			TINYAAC_WIN_REFIID(KSDATAFORMAT_SUBTYPE_PCM));
	}
	return 0;
}

static void tinyaac_win_copy_samples(float *output, const BYTE *input, UINT32 frames,
	const WAVEFORMATEX *format, DWORD flags)
{
	size_t samples = (size_t)frames * format->nChannels;
	size_t index;
	if (flags & AUDCLNT_BUFFERFLAGS_SILENT) {
		memset(output, 0, samples * sizeof(*output));
		return;
	}
	if (tinyaac_win_format_is_float(format) && format->wBitsPerSample == 32) {
		memcpy(output, input, samples * sizeof(*output));
		return;
	}
	if (tinyaac_win_format_is_float(format) && format->wBitsPerSample == 64) {
		const double *source = (const double *)input;
		for (index = 0; index < samples; ++index)
			output[index] = (float)source[index];
		return;
	}
	if (tinyaac_win_format_is_pcm(format) && format->wBitsPerSample == 8) {
		for (index = 0; index < samples; ++index)
			output[index] = ((float)input[index] - 128.0f) / 128.0f;
	} else if (tinyaac_win_format_is_pcm(format) && format->wBitsPerSample == 16) {
		const int16_t *source = (const int16_t *)input;
		for (index = 0; index < samples; ++index)
			output[index] = (float)source[index] / 32768.0f;
	} else if (tinyaac_win_format_is_pcm(format) && format->wBitsPerSample == 32) {
		const int32_t *source = (const int32_t *)input;
		for (index = 0; index < samples; ++index)
			output[index] = (float)((double)source[index] / 2147483648.0);
	} else {
		memset(output, 0, samples * sizeof(*output));
	}
}

static void tinyaac_win_drain_capture(struct tinyaac_win_capture *backend,
	IAudioCaptureClient *capture_client, const WAVEFORMATEX *format)
{
	UINT32 frames;
	HRESULT result;
	while (SUCCEEDED(result = IAudioCaptureClient_GetNextPacketSize(capture_client, &frames)) && frames) {
		BYTE *buffer;
		DWORD flags;
		UINT64 device_position;
		UINT64 timestamp;
		struct tinyaac_win_work *work;
		size_t bytes = (size_t)frames * format->nChannels * sizeof(float);
		result = IAudioCaptureClient_GetBuffer(capture_client, &buffer, &frames, &flags,
			&device_position, &timestamp);
		if (FAILED(result))
			break;
		work = (struct tinyaac_win_work *)malloc(sizeof(*work) + bytes - sizeof(float));
		if (work) {
			memset(work, 0, sizeof(*work));
			work->frame.samples = work->samples;
			work->frame.frame_count = frames;
			work->frame.channels = format->nChannels;
			work->frame.sample_rate = format->nSamplesPerSec;
			work->frame.timestamp_ns = GetTickCount64() * 1000000ULL;
			tinyaac_win_copy_samples(work->samples, buffer, frames, format, flags);
			tinyaac_win_enqueue(backend, work);
		}
		IAudioCaptureClient_ReleaseBuffer(capture_client, frames);
	}
}

static DWORD WINAPI tinyaac_win_capture_thread(void *data)
{
	tinyaac_capture *capture = (tinyaac_capture *)data;
	struct tinyaac_win_capture *backend = (struct tinyaac_win_capture *)capture->backend;
	HMODULE module = NULL;
	tinyaac_activate_audio_interface_async_fn activate = NULL;
	struct tinyaac_win_activation_handler *handler = NULL;
	IActivateAudioInterfaceAsyncOperation *operation = NULL;
	IAudioClient *audio_client = NULL;
	IAudioCaptureClient *capture_client = NULL;
	WAVEFORMATEX *format = NULL;
	AUDIOCLIENT_ACTIVATION_PARAMS parameters;
	PROPVARIANT activation_parameters;
	HRESULT result = E_FAIL;
	int com_initialized = 0;
	DWORD handles_count;
	HANDLE handles[3];

	result = CoInitializeEx(NULL, COINIT_MULTITHREADED);
	if (FAILED(result))
		goto done;
	com_initialized = 1;
	module = LoadLibraryW(L"Mmdevapi.dll");
	if (!module)
		goto done;
	activate = (tinyaac_activate_audio_interface_async_fn)GetProcAddress(module,
		"ActivateAudioInterfaceAsync");
	if (!activate)
		goto done;
	handler = tinyaac_win_activation_handler_create();
	if (!handler)
		goto done;
	memset(&parameters, 0, sizeof(parameters));
	parameters.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
	parameters.ProcessLoopbackParams.TargetProcessId = backend->process_id;
	parameters.ProcessLoopbackParams.ProcessLoopbackMode = PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;
	PropVariantInit(&activation_parameters);
	activation_parameters.vt = VT_BLOB;
	activation_parameters.blob.cbSize = sizeof(parameters);
	activation_parameters.blob.pBlobData = (BYTE *)&parameters;
	result = activate(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, TINYAAC_WIN_REFIID(IID_IAudioClient),
		&activation_parameters, &handler->iface, &operation);
	if (FAILED(result) || WaitForSingleObject(handler->completed_event, 5000) != WAIT_OBJECT_0)
		goto done;
	result = handler->result;
	if (FAILED(result) || !handler->client)
		goto done;
	audio_client = handler->client;
	handler->client = NULL;
	result = IAudioClient_GetMixFormat(audio_client, &format);
	if (FAILED(result) || !format ||
		(!tinyaac_win_format_is_float(format) && !tinyaac_win_format_is_pcm(format)))
		goto done;
	backend->audio_event = CreateEventW(NULL, FALSE, FALSE, NULL);
	if (!backend->audio_event)
		goto done;
	result = IAudioClient_Initialize(audio_client, AUDCLNT_SHAREMODE_SHARED,
		AUDCLNT_STREAMFLAGS_EVENTCALLBACK, 0, 0, format, NULL);
	if (FAILED(result))
		goto done;
	result = IAudioClient_SetEventHandle(audio_client, backend->audio_event);
	if (FAILED(result))
		goto done;
	result = IAudioClient_GetService(audio_client, TINYAAC_WIN_REFIID(IID_IAudioCaptureClient),
		(void **)&capture_client);
	if (FAILED(result))
		goto done;
	result = IAudioClient_Start(audio_client);
	if (FAILED(result))
		goto done;
	backend->start_result = S_OK;
	SetEvent(backend->ready_event);
	handles[0] = backend->stop_event;
	handles[1] = backend->audio_event;
	handles_count = 2;
	if (backend->process_handle)
		handles[handles_count++] = backend->process_handle;
	for (;;) {
		DWORD wait = WaitForMultipleObjects(handles_count, handles, FALSE, INFINITE);
		if (wait == WAIT_OBJECT_0)
			break;
		if (wait == WAIT_OBJECT_0 + 1)
			tinyaac_win_drain_capture(backend, capture_client, format);
		else if (handles_count == 3 && wait == WAIT_OBJECT_0 + 2) {
			tinyaac_win_enqueue_event(backend, TINYAAC_EVENT_TARGET_ENDED,
				TINYAAC_ERR_NOT_FOUND, "Selected process ended");
			break;
		}
	}
	IAudioClient_Stop(audio_client);

done:
	if (FAILED(result)) {
		backend->start_result = result;
		SetEvent(backend->ready_event);
	}
	if (capture_client)
		IAudioCaptureClient_Release(capture_client);
	if (format)
		CoTaskMemFree(format);
	if (audio_client)
		IAudioClient_Release(audio_client);
	if (operation)
		IActivateAudioInterfaceAsyncOperation_Release(operation);
	if (handler) {
		CloseHandle(handler->completed_event);
		IActivateAudioInterfaceCompletionHandler_Release(&handler->iface);
	}
	if (module)
		FreeLibrary(module);
	if (com_initialized)
		CoUninitialize();
	return 0;
}

static BOOL CALLBACK tinyaac_win_enum_window(HWND window, LPARAM data)
{
	tinyaac_app_list *list = (tinyaac_app_list *)data;
	DWORD process_id = 0;
	int title_length;
	int utf8_length;
	wchar_t *title;
	char *utf8;
	char identifier[64];
	size_t index;
	if (!IsWindowVisible(window) || !(title_length = GetWindowTextLengthW(window)))
		return TRUE;
	GetWindowThreadProcessId(window, &process_id);
	if (!process_id)
		return TRUE;
	for (index = 0; index < list->count; ++index) {
		if (list->apps[index].process_id == process_id)
			return TRUE;
	}
	title = (wchar_t *)calloc((size_t)title_length + 1, sizeof(*title));
	if (!title)
		return FALSE;
	GetWindowTextW(window, title, title_length + 1);
	utf8_length = WideCharToMultiByte(CP_UTF8, 0, title, -1, NULL, 0, NULL, NULL);
	utf8 = utf8_length ? (char *)calloc((size_t)utf8_length, 1) : NULL;
	if (utf8)
		WideCharToMultiByte(CP_UTF8, 0, title, -1, utf8, utf8_length, NULL, NULL);
	free(title);
	if (!utf8)
		return FALSE;
	snprintf(identifier, sizeof(identifier), "win-pid:%lu", (unsigned long)process_id);
	tinyaac_internal_append_app(list, utf8, identifier, process_id);
	free(utf8);
	return TRUE;
}

static tinyaac_status tinyaac_platform_init(void)
{
	OSVERSIONINFOEXW version;
	typedef LONG (WINAPI *tinyaac_rtl_get_version_fn)(OSVERSIONINFOW *);
	tinyaac_rtl_get_version_fn rtl_get_version = NULL;
	HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
	LONG version_result;
	memset(&version, 0, sizeof(version));
	version.dwOSVersionInfoSize = sizeof(version);
	if (ntdll)
		rtl_get_version = (tinyaac_rtl_get_version_fn)GetProcAddress(ntdll, "RtlGetVersion");
	version_result = rtl_get_version ? rtl_get_version((OSVERSIONINFOW *)&version) :
		(GetVersionExW((OSVERSIONINFOW *)&version) ? 0 : -1);
	if (version_result != 0 || version.dwMajorVersion < 10 ||
		version.dwBuildNumber < 19041) {
		tinyaac_internal_set_error("Windows 10 build 19041 or newer is required");
		return TINYAAC_ERR_PLATFORM_UNAVAILABLE;
	}
	return TINYAAC_OK;
}

static void tinyaac_platform_shutdown(void) {}

static tinyaac_status tinyaac_platform_enumerate(tinyaac_app_list *list)
{
	if (!list)
		return TINYAAC_ERR_INVALID_ARGUMENT;
	if (!EnumWindows(tinyaac_win_enum_window, (LPARAM)list))
		return TINYAAC_ERR_BACKEND;
	return TINYAAC_OK;
}

static void tinyaac_win_capture_cleanup(tinyaac_capture *capture,
	struct tinyaac_win_capture *backend)
{
	struct tinyaac_win_work *work;
	if (!backend)
		return;
	InterlockedExchange(&backend->closing, 1);
	if (backend->stop_event)
		SetEvent(backend->stop_event);
	if (backend->capture_thread) {
		WaitForSingleObject(backend->capture_thread, INFINITE);
		CloseHandle(backend->capture_thread);
	}
	EnterCriticalSection(&backend->queue_lock);
	WakeAllConditionVariable(&backend->queue_ready);
	LeaveCriticalSection(&backend->queue_lock);
	if (backend->callback_worker_started) {
		WaitForSingleObject(backend->callback_thread, INFINITE);
		CloseHandle(backend->callback_thread);
	}
	while ((work = backend->queue_head) != NULL) {
		backend->queue_head = work->next;
		free(work);
	}
	if (backend->process_handle)
		CloseHandle(backend->process_handle);
	if (backend->audio_event)
		CloseHandle(backend->audio_event);
	if (backend->ready_event)
		CloseHandle(backend->ready_event);
	if (backend->stop_event)
		CloseHandle(backend->stop_event);
	DeleteCriticalSection(&backend->queue_lock);
	if (capture && capture->backend == backend)
		capture->backend = NULL;
	free(backend);
}

static tinyaac_status tinyaac_platform_capture_start(tinyaac_capture *capture)
{
	struct tinyaac_win_capture *backend;
	if (!capture || strncmp(capture->identifier, "win-pid:", 8) != 0)
		return TINYAAC_ERR_INVALID_ARGUMENT;
	backend = (struct tinyaac_win_capture *)calloc(1, sizeof(*backend));
	if (!backend)
		return TINYAAC_ERR_OUT_OF_MEMORY;
	backend->process_id = capture->process_id;
	InitializeCriticalSection(&backend->queue_lock);
	InitializeConditionVariable(&backend->queue_ready);
	backend->stop_event = CreateEventW(NULL, TRUE, FALSE, NULL);
	backend->ready_event = CreateEventW(NULL, TRUE, FALSE, NULL);
	backend->process_handle = OpenProcess(SYNCHRONIZE, FALSE, backend->process_id);
	if (!backend->stop_event || !backend->ready_event)
		goto failed;
	capture->backend = backend;
	backend->callback_thread = CreateThread(NULL, 0, tinyaac_win_callback_thread,
		capture, 0, NULL);
	if (!backend->callback_thread)
		goto failed;
	backend->callback_worker_started = 1;
	backend->capture_thread = CreateThread(NULL, 0, tinyaac_win_capture_thread,
		capture, 0, NULL);
	if (!backend->capture_thread)
		goto failed;
	if (WaitForSingleObject(backend->ready_event, 6000) != WAIT_OBJECT_0 ||
		FAILED(backend->start_result))
		goto failed;
	return TINYAAC_OK;

failed:
	tinyaac_internal_set_error("Unable to activate WASAPI process loopback for the selected application");
	tinyaac_win_capture_cleanup(capture, backend);
	return TINYAAC_ERR_BACKEND;
}

static tinyaac_status tinyaac_platform_capture_stop(tinyaac_capture *capture)
{
	if (!capture || !capture->backend)
		return TINYAAC_ERR_INVALID_STATE;
	tinyaac_win_capture_cleanup(capture, (struct tinyaac_win_capture *)capture->backend);
	return TINYAAC_OK;
}

static void tinyaac_platform_capture_destroy(tinyaac_capture *capture)
{
	if (capture && capture->backend)
		tinyaac_win_capture_cleanup(capture, (struct tinyaac_win_capture *)capture->backend);
}

#undef TINYAAC_WIN_REFIID

#endif /* _WIN32 */
/* End tinyaac_win.h */

/* Begin tinyaac_pipewire.h */
/* Linux/PipeWire backend fragment. */
#ifdef __linux__

#include <pthread.h>
#include <pipewire/pipewire.h>
#include <spa/param/audio/raw-utils.h>
#include <spa/pod/builder.h>

struct tinyaac_pipewire_client_info {
	uint32_t id;
	uint32_t process_id;
	char *app_name;
	char *binary;
	struct pw_client *proxy;
	struct spa_hook listener;
};

struct tinyaac_pipewire_node_info {
	uint32_t id;
	uint32_t client_id;
	uint32_t process_id;
	char *app_name;
	char *binary;
	char *node_name;
};

struct tinyaac_pipewire_enumeration {
	struct pw_thread_loop *loop;
	struct pw_registry *registry;
	struct pw_core *core;
	struct pw_core_events core_events;
	struct pw_registry_events registry_events;
	struct pw_client_events client_events;
	tinyaac_app_list *list;
	struct tinyaac_pipewire_client_info **clients;
	struct tinyaac_pipewire_node_info *nodes;
	size_t client_count;
	size_t node_count;
	int out_of_memory;
	int pending_sync;
	int sync_stage;
	int core_error;
};

enum tinyaac_pipewire_work_kind {
	TINYAAC_PIPEWIRE_WORK_AUDIO,
	TINYAAC_PIPEWIRE_WORK_EVENT
};

struct tinyaac_pipewire_work {
	struct tinyaac_pipewire_work *next;
	enum tinyaac_pipewire_work_kind kind;
	tinyaac_audio_frame frame;
	tinyaac_event event;
	tinyaac_status status;
	char message[128];
	float samples[1];
};

struct tinyaac_pipewire_capture {
	struct pw_thread_loop *loop;
	struct pw_context *context;
	struct pw_core *core;
	struct pw_stream *stream;
	struct spa_hook stream_listener;
	struct pw_stream_events stream_events;
	pthread_t callback_thread;
	pthread_mutex_t queue_mutex;
	pthread_cond_t queue_cond;
	struct tinyaac_pipewire_work *queue_head;
	struct tinyaac_pipewire_work *queue_tail;
	uint32_t channels;
	uint32_t sample_rate;
	enum spa_audio_format format;
	int worker_started;
	int closing;
	int loop_started;
};

static void tinyaac_pipewire_done(void *data, uint32_t id, int seq)
{
	struct tinyaac_pipewire_enumeration *enumeration =
		(struct tinyaac_pipewire_enumeration *)data;
	(void)id;
	if (seq == enumeration->pending_sync) {
		if (enumeration->sync_stage == 0) {
			enumeration->sync_stage = 1;
			enumeration->pending_sync = pw_core_sync(enumeration->core, PW_ID_CORE, 0);
			if (enumeration->pending_sync < 0) {
				enumeration->core_error = enumeration->pending_sync;
				pw_thread_loop_signal(enumeration->loop, false);
			}
			return;
		}
		enumeration->pending_sync = 0;
		pw_thread_loop_signal(enumeration->loop, false);
	}
}

static void tinyaac_pipewire_error(void *data, uint32_t id, int seq, int res,
	const char *message)
{
	struct tinyaac_pipewire_enumeration *enumeration =
		(struct tinyaac_pipewire_enumeration *)data;
	(void)id;
	(void)seq;
	(void)message;
	enumeration->core_error = res ? res : -1;
	tinyaac_internal_set_error("PipeWire reported a core error while listing applications");
	pw_thread_loop_signal(enumeration->loop, false);
}

static uint32_t tinyaac_pipewire_property_u32(const struct spa_dict *props,
	const char *key)
{
	const char *value = spa_dict_lookup(props, key);
	return value ? (uint32_t)strtoul(value, NULL, 10) : 0;
}

static void tinyaac_pipewire_client_info(void *data, const struct pw_client_info *info)
{
	struct tinyaac_pipewire_client_info *client =
		(struct tinyaac_pipewire_client_info *)data;
	if (!info || !info->props)
		return;
	client->process_id = tinyaac_pipewire_property_u32(info->props, PW_KEY_APP_PROCESS_ID);
	free(client->app_name);
	free(client->binary);
	client->app_name = tinyaac_internal_strdup(spa_dict_lookup(info->props, PW_KEY_APP_NAME));
	client->binary = tinyaac_internal_strdup(spa_dict_lookup(info->props, PW_KEY_APP_PROCESS_BINARY));
}

static void tinyaac_pipewire_free_enumeration(struct tinyaac_pipewire_enumeration *enumeration)
{
	size_t index;
	for (index = 0; index < enumeration->client_count; ++index) {
		free(enumeration->clients[index]->app_name);
		free(enumeration->clients[index]->binary);
		free(enumeration->clients[index]);
	}
	for (index = 0; index < enumeration->node_count; ++index) {
		free(enumeration->nodes[index].app_name);
		free(enumeration->nodes[index].binary);
		free(enumeration->nodes[index].node_name);
	}
	free(enumeration->clients);
	free(enumeration->nodes);
}

static void tinyaac_pipewire_global(void *data, uint32_t id, uint32_t permissions,
	const char *type, uint32_t version, const struct spa_dict *props)
{
	struct tinyaac_pipewire_enumeration *enumeration =
		(struct tinyaac_pipewire_enumeration *)data;
	const char *media_class;
	(void)permissions;
	(void)version;

	if (strcmp(type, PW_TYPE_INTERFACE_Client) == 0) {
		struct tinyaac_pipewire_client_info **clients =
			(struct tinyaac_pipewire_client_info **)realloc(enumeration->clients,
				(enumeration->client_count + 1) * sizeof(*clients));
		struct tinyaac_pipewire_client_info *client;
		if (!clients)
			goto out_of_memory;
		enumeration->clients = clients;
		client = (struct tinyaac_pipewire_client_info *)calloc(1, sizeof(*client));
		if (!client)
			goto out_of_memory;
		enumeration->clients[enumeration->client_count++] = client;
		client->id = id;
		client->process_id = tinyaac_pipewire_property_u32(props, PW_KEY_APP_PROCESS_ID);
		client->app_name = tinyaac_internal_strdup(spa_dict_lookup(props, PW_KEY_APP_NAME));
		client->binary = tinyaac_internal_strdup(spa_dict_lookup(props, PW_KEY_APP_PROCESS_BINARY));
		client->proxy = (struct pw_client *)pw_registry_bind(enumeration->registry,
			id, PW_TYPE_INTERFACE_Client, PW_VERSION_CLIENT, 0);
		if (client->proxy)
			pw_client_add_listener(client->proxy, &client->listener,
				&enumeration->client_events, client);
		return;
	}
	if (strcmp(type, PW_TYPE_INTERFACE_Node) != 0)
		return;
	media_class = spa_dict_lookup(props, PW_KEY_MEDIA_CLASS);
	if (!media_class || strcmp(media_class, "Stream/Output/Audio") != 0)
		return;
	{
		struct tinyaac_pipewire_node_info *nodes =
			(struct tinyaac_pipewire_node_info *)realloc(enumeration->nodes,
				(enumeration->node_count + 1) * sizeof(*nodes));
		if (!nodes)
			goto out_of_memory;
		enumeration->nodes = nodes;
		nodes = &enumeration->nodes[enumeration->node_count++];
		memset(nodes, 0, sizeof(*nodes));
		nodes->id = id;
		nodes->client_id = tinyaac_pipewire_property_u32(props, PW_KEY_CLIENT_ID);
		nodes->process_id = tinyaac_pipewire_property_u32(props, PW_KEY_APP_PROCESS_ID);
		nodes->app_name = tinyaac_internal_strdup(spa_dict_lookup(props, PW_KEY_APP_NAME));
		nodes->binary = tinyaac_internal_strdup(spa_dict_lookup(props, PW_KEY_APP_PROCESS_BINARY));
		nodes->node_name = tinyaac_internal_strdup(spa_dict_lookup(props, PW_KEY_NODE_NAME));
		return;
	}

out_of_memory:
	enumeration->out_of_memory = 1;
}

static tinyaac_status tinyaac_pipewire_finish_enumeration(
	struct tinyaac_pipewire_enumeration *enumeration)
{
	size_t node_index;
	if (enumeration->out_of_memory)
		return TINYAAC_ERR_OUT_OF_MEMORY;
	for (node_index = 0; node_index < enumeration->node_count; ++node_index) {
		struct tinyaac_pipewire_node_info *node = &enumeration->nodes[node_index];
		const char *display_name = node->app_name;
		uint32_t process_id = node->process_id;
		size_t client_index;
		char identifier[64];
		for (client_index = 0; client_index < enumeration->client_count; ++client_index) {
			struct tinyaac_pipewire_client_info *client = enumeration->clients[client_index];
			if (client->id != node->client_id)
				continue;
			if (!display_name)
				display_name = client->app_name;
			if (!process_id)
				process_id = client->process_id;
			break;
		}
		if (!display_name)
			display_name = node->binary ? node->binary : node->node_name;
		if (!display_name)
			continue;
		snprintf(identifier, sizeof(identifier), "pipewire-node:%u", node->id);
		if (tinyaac_internal_append_app(enumeration->list, display_name, identifier,
			process_id) != TINYAAC_OK)
			return TINYAAC_ERR_OUT_OF_MEMORY;
	}
	return TINYAAC_OK;
}

static void tinyaac_pipewire_enqueue(struct tinyaac_pipewire_capture *backend,
	struct tinyaac_pipewire_work *work)
{
	pthread_mutex_lock(&backend->queue_mutex);
	if (backend->closing) {
		pthread_mutex_unlock(&backend->queue_mutex);
		free(work);
		return;
	}
	if (backend->queue_tail)
		backend->queue_tail->next = work;
	else
		backend->queue_head = work;
	backend->queue_tail = work;
	pthread_cond_signal(&backend->queue_cond);
	pthread_mutex_unlock(&backend->queue_mutex);
}

static void *tinyaac_pipewire_callback_thread(void *data)
{
	tinyaac_capture *capture = (tinyaac_capture *)data;
	struct tinyaac_pipewire_capture *backend =
		(struct tinyaac_pipewire_capture *)capture->backend;

	for (;;) {
		struct tinyaac_pipewire_work *work;
		pthread_mutex_lock(&backend->queue_mutex);
		while (!backend->queue_head && !backend->closing)
			pthread_cond_wait(&backend->queue_cond, &backend->queue_mutex);
		if (!backend->queue_head && backend->closing) {
			pthread_mutex_unlock(&backend->queue_mutex);
			break;
		}
		work = backend->queue_head;
		backend->queue_head = work->next;
		if (!backend->queue_head)
			backend->queue_tail = NULL;
		pthread_mutex_unlock(&backend->queue_mutex);

		if (work->kind == TINYAAC_PIPEWIRE_WORK_AUDIO) {
			if (capture->on_audio)
				capture->on_audio(&work->frame, capture->user_data);
		} else if (capture->on_event) {
			capture->on_event(work->event, work->status, work->message,
				capture->user_data);
		}
		free(work);
	}
	return NULL;
}

static void tinyaac_pipewire_enqueue_event(struct tinyaac_pipewire_capture *backend,
	tinyaac_event event, tinyaac_status status, const char *message)
{
	struct tinyaac_pipewire_work *work =
		(struct tinyaac_pipewire_work *)calloc(1, sizeof(*work));
	if (!work)
		return;
	work->kind = TINYAAC_PIPEWIRE_WORK_EVENT;
	work->event = event;
	work->status = status;
	if (message)
		snprintf(work->message, sizeof(work->message), "%s", message);
	tinyaac_pipewire_enqueue(backend, work);
}

static void tinyaac_pipewire_stream_process(void *data)
{
	struct tinyaac_pipewire_capture *backend =
		(struct tinyaac_pipewire_capture *)data;
	struct pw_buffer *pw_buffer = pw_stream_dequeue_buffer(backend->stream);
	struct spa_buffer *buffer;
	struct spa_data *audio;
	struct tinyaac_pipewire_work *work;
	size_t frames;
	size_t bytes;
	uint32_t expected_stride;

	if (!pw_buffer)
		return;
	buffer = pw_buffer->buffer;
	if (!buffer || !buffer->n_datas || !backend->sample_rate ||
		backend->format != SPA_AUDIO_FORMAT_F32_LE)
		goto queue;
	audio = &buffer->datas[0];
	expected_stride = backend->channels * (uint32_t)sizeof(float);
	if (!audio->chunk || !audio->data || audio->type != SPA_DATA_MemPtr ||
		!audio->chunk->stride ||
		audio->chunk->stride != (int32_t)expected_stride)
		goto queue;
	frames = audio->chunk->size / audio->chunk->stride;
	if (!frames)
		goto queue;
	bytes = frames * audio->chunk->stride;
	work = (struct tinyaac_pipewire_work *)malloc(sizeof(*work) + bytes - sizeof(float));
	if (!work)
		goto queue;
	memset(work, 0, sizeof(*work));
	work->kind = TINYAAC_PIPEWIRE_WORK_AUDIO;
	work->frame.samples = work->samples;
	work->frame.frame_count = frames;
	work->frame.channels = backend->channels;
	work->frame.sample_rate = backend->sample_rate;
	work->frame.timestamp_ns = pw_stream_get_nsec(backend->stream);
	memcpy(work->samples, (const unsigned char *)audio->data + audio->chunk->offset, bytes);
	tinyaac_pipewire_enqueue(backend, work);

queue:
	pw_stream_queue_buffer(backend->stream, pw_buffer);
}

static void tinyaac_pipewire_stream_param_changed(void *data, uint32_t id,
	const struct spa_pod *param)
{
	struct tinyaac_pipewire_capture *backend =
		(struct tinyaac_pipewire_capture *)data;
	struct spa_audio_info_raw format;
	if (!param || id != SPA_PARAM_Format)
		return;
	if (spa_format_audio_raw_parse(param, &format) < 0 ||
		format.format != SPA_AUDIO_FORMAT_F32_LE || !format.channels || !format.rate) {
		backend->format = SPA_AUDIO_FORMAT_UNKNOWN;
		tinyaac_pipewire_enqueue_event(backend, TINYAAC_EVENT_BACKEND_ERROR,
			TINYAAC_ERR_UNSUPPORTED_FORMAT, "PipeWire did not negotiate interleaved float32 audio");
		return;
	}
	backend->format = format.format;
	backend->channels = format.channels;
	backend->sample_rate = format.rate;
}

static void tinyaac_pipewire_stream_state_changed(void *data,
	enum pw_stream_state old, enum pw_stream_state state, const char *error)
{
	struct tinyaac_pipewire_capture *backend =
		(struct tinyaac_pipewire_capture *)data;
	if (backend->closing)
		return;
	if (state == PW_STREAM_STATE_ERROR) {
		tinyaac_pipewire_enqueue_event(backend, TINYAAC_EVENT_BACKEND_ERROR,
			TINYAAC_ERR_BACKEND, error ? error : "PipeWire stream error");
	} else if (old == PW_STREAM_STATE_STREAMING && state == PW_STREAM_STATE_UNCONNECTED) {
		tinyaac_pipewire_enqueue_event(backend, TINYAAC_EVENT_TARGET_ENDED,
			TINYAAC_ERR_NOT_FOUND, "Selected PipeWire application ended");
	}
}

static tinyaac_status tinyaac_platform_init(void)
{
	pw_init(NULL, NULL);
	return TINYAAC_OK;
}

static void tinyaac_platform_shutdown(void)
{
	pw_deinit();
}

static tinyaac_status tinyaac_platform_enumerate(tinyaac_app_list *list)
{
	struct tinyaac_pipewire_enumeration enumeration;
	struct pw_context *context = NULL;
	struct pw_core *core = NULL;
	struct pw_registry *registry = NULL;
	struct spa_hook core_listener;
	struct spa_hook registry_listener;
	tinyaac_status status = TINYAAC_ERR_BACKEND;
	int loop_started = 0;
	int core_listening = 0;
	int registry_listening = 0;

	if (!list)
		return TINYAAC_ERR_INVALID_ARGUMENT;
	memset(&enumeration, 0, sizeof(enumeration));
	enumeration.list = list;
	memset(&core_listener, 0, sizeof(core_listener));
	memset(&registry_listener, 0, sizeof(registry_listener));
	enumeration.core_events.version = PW_VERSION_CORE_EVENTS;
	enumeration.core_events.done = tinyaac_pipewire_done;
	enumeration.core_events.error = tinyaac_pipewire_error;
	enumeration.registry_events.version = PW_VERSION_REGISTRY_EVENTS;
	enumeration.registry_events.global = tinyaac_pipewire_global;
	enumeration.client_events.version = PW_VERSION_CLIENT_EVENTS;
	enumeration.client_events.info = tinyaac_pipewire_client_info;
	enumeration.loop = pw_thread_loop_new("tinyaac-enumerate", NULL);
	if (!enumeration.loop)
		goto done;
	context = pw_context_new(pw_thread_loop_get_loop(enumeration.loop), NULL, 0);
	if (!context)
		goto done;
	if (pw_thread_loop_start(enumeration.loop) < 0)
		goto done;
	loop_started = 1;
	pw_thread_loop_lock(enumeration.loop);
	core = pw_context_connect(context, NULL, 0);
	if (!core)
		goto unlock;
	enumeration.core = core;
	pw_core_add_listener(core, &core_listener, &enumeration.core_events, &enumeration);
	core_listening = 1;
	registry = pw_core_get_registry(core, PW_VERSION_REGISTRY, 0);
	if (!registry)
		goto unlock;
	enumeration.registry = registry;
	pw_registry_add_listener(registry, &registry_listener,
		&enumeration.registry_events, &enumeration);
	registry_listening = 1;
	enumeration.pending_sync = pw_core_sync(core, PW_ID_CORE, 0);
	if (enumeration.pending_sync < 0)
		goto unlock;
	while (enumeration.pending_sync && !enumeration.core_error)
		pw_thread_loop_wait(enumeration.loop);
	status = enumeration.core_error ? TINYAAC_ERR_BACKEND :
		tinyaac_pipewire_finish_enumeration(&enumeration);

unlock:
	if (registry_listening)
		spa_hook_remove(&registry_listener);
	if (registry)
		pw_proxy_destroy((struct pw_proxy *)registry);
	if (core_listening)
		spa_hook_remove(&core_listener);
	{
		size_t client_index;
		for (client_index = 0; client_index < enumeration.client_count; ++client_index) {
			if (enumeration.clients[client_index]->proxy) {
				spa_hook_remove(&enumeration.clients[client_index]->listener);
				pw_proxy_destroy((struct pw_proxy *)enumeration.clients[client_index]->proxy);
			}
		}
	}
	if (core)
		pw_core_disconnect(core);
	pw_thread_loop_unlock(enumeration.loop);
done:
	if (context)
		pw_context_destroy(context);
	if (enumeration.loop) {
		if (loop_started)
			pw_thread_loop_stop(enumeration.loop);
		pw_thread_loop_destroy(enumeration.loop);
	}
	tinyaac_pipewire_free_enumeration(&enumeration);
	if (status != TINYAAC_OK && !tinyaac_last_error()[0])
		tinyaac_internal_set_error("Unable to connect to the PipeWire daemon");
	return status;
}

static void tinyaac_pipewire_capture_cleanup(tinyaac_capture *capture,
	struct tinyaac_pipewire_capture *backend)
{
	struct tinyaac_pipewire_work *work;
	if (!backend)
		return;
	if (backend->loop && backend->loop_started) {
		pw_thread_loop_lock(backend->loop);
		backend->closing = 1;
		if (backend->stream) {
			pw_stream_disconnect(backend->stream);
			spa_hook_remove(&backend->stream_listener);
			pw_stream_destroy(backend->stream);
		}
		if (backend->core)
			pw_core_disconnect(backend->core);
		pw_thread_loop_unlock(backend->loop);
	}
	pthread_mutex_lock(&backend->queue_mutex);
	backend->closing = 1;
	pthread_cond_signal(&backend->queue_cond);
	pthread_mutex_unlock(&backend->queue_mutex);
	if (backend->worker_started)
		pthread_join(backend->callback_thread, NULL);
	while ((work = backend->queue_head) != NULL) {
		backend->queue_head = work->next;
		free(work);
	}
	if (backend->loop) {
		if (backend->loop_started)
			pw_thread_loop_stop(backend->loop);
		if (backend->context)
			pw_context_destroy(backend->context);
		pw_thread_loop_destroy(backend->loop);
	} else if (backend->context) {
		pw_context_destroy(backend->context);
	}
	pthread_cond_destroy(&backend->queue_cond);
	pthread_mutex_destroy(&backend->queue_mutex);
	if (capture && capture->backend == backend)
		capture->backend = NULL;
	free(backend);
}

static tinyaac_status tinyaac_platform_capture_start(tinyaac_capture *capture)
{
	struct tinyaac_pipewire_capture *backend;
	const char *value;
	char *end;
	unsigned long target_id;
	uint8_t pod_buffer[256];
	struct spa_pod_builder builder = SPA_POD_BUILDER_INIT(pod_buffer, sizeof(pod_buffer));
	const struct spa_pod *params[1];

	if (!capture || strncmp(capture->identifier, "pipewire-node:", 14) != 0)
		return TINYAAC_ERR_INVALID_ARGUMENT;
	value = capture->identifier + 14;
	target_id = strtoul(value, &end, 10);
	if (!*value || *end || target_id > UINT32_MAX)
		return TINYAAC_ERR_INVALID_ARGUMENT;
	backend = (struct tinyaac_pipewire_capture *)calloc(1, sizeof(*backend));
	if (!backend)
		return TINYAAC_ERR_OUT_OF_MEMORY;
	if (pthread_mutex_init(&backend->queue_mutex, NULL) ||
		pthread_cond_init(&backend->queue_cond, NULL)) {
		free(backend);
		return TINYAAC_ERR_BACKEND;
	}
	backend->format = SPA_AUDIO_FORMAT_UNKNOWN;
	backend->loop = pw_thread_loop_new("tinyaac-capture", NULL);
	if (!backend->loop)
		goto failed;
	backend->context = pw_context_new(pw_thread_loop_get_loop(backend->loop), NULL, 0);
	if (!backend->context || pw_thread_loop_start(backend->loop) < 0)
		goto failed;
	backend->loop_started = 1;
	pw_thread_loop_lock(backend->loop);
	backend->core = pw_context_connect(backend->context, NULL, 0);
	if (!backend->core)
		goto unlock_failed;
	backend->stream_events.version = PW_VERSION_STREAM_EVENTS;
	backend->stream_events.process = tinyaac_pipewire_stream_process;
	backend->stream_events.param_changed = tinyaac_pipewire_stream_param_changed;
	backend->stream_events.state_changed = tinyaac_pipewire_stream_state_changed;
	backend->stream = pw_stream_new(backend->core, "tinyaac application capture",
		pw_properties_new(PW_KEY_MEDIA_TYPE, "Audio", PW_KEY_MEDIA_CATEGORY,
			"Capture", PW_KEY_MEDIA_NAME, "tinyaac application capture", NULL));
	if (!backend->stream)
		goto unlock_failed;
	pw_stream_add_listener(backend->stream, &backend->stream_listener,
		&backend->stream_events, backend);
	params[0] = (const struct spa_pod *)spa_pod_builder_add_object(&builder, SPA_TYPE_OBJECT_Format,
		SPA_PARAM_EnumFormat, SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_audio),
		SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
		SPA_FORMAT_AUDIO_format, SPA_POD_Id(SPA_AUDIO_FORMAT_F32_LE));
	if (!params[0] || pw_stream_connect(backend->stream, PW_DIRECTION_INPUT,
		(uint32_t)target_id, (enum pw_stream_flags)(PW_STREAM_FLAG_AUTOCONNECT |
		PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_DONT_RECONNECT), params, 1) < 0)
		goto unlock_failed;
	capture->backend = backend;
	if (pthread_create(&backend->callback_thread, NULL,
		tinyaac_pipewire_callback_thread, capture) != 0) {
		capture->backend = NULL;
		goto unlock_failed;
	}
	backend->worker_started = 1;
	pw_thread_loop_unlock(backend->loop);
	return TINYAAC_OK;

unlock_failed:
	pw_thread_loop_unlock(backend->loop);
failed:
	tinyaac_internal_set_error("Unable to create a PipeWire capture stream for the selected application");
	tinyaac_pipewire_capture_cleanup(NULL, backend);
	return TINYAAC_ERR_BACKEND;
}

static tinyaac_status tinyaac_platform_capture_stop(tinyaac_capture *capture)
{
	if (!capture || !capture->backend)
		return TINYAAC_ERR_INVALID_STATE;
	tinyaac_pipewire_capture_cleanup(capture,
		(struct tinyaac_pipewire_capture *)capture->backend);
	return TINYAAC_OK;
}

static void tinyaac_platform_capture_destroy(tinyaac_capture *capture)
{
	if (capture && capture->backend)
		tinyaac_pipewire_capture_cleanup(capture,
			(struct tinyaac_pipewire_capture *)capture->backend);
}

#endif /* __linux__ */
/* End tinyaac_pipewire.h */

/* Begin tinyaac_macos.h */
/* macOS Core Audio process-tap backend. The implementation translation unit
 * must be compiled as Objective-C with ARC enabled. */
#ifdef __APPLE__

#if !defined(__OBJC__)
#error "Define TINYAAC_IMPLEMENTATION in an Objective-C (.m) translation unit on macOS."
#endif

#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

static tinyaac_status tinyaac_macos_process_objects(AudioObjectID **out_objects,
	UInt32 *out_count)
{
	AudioObjectPropertyAddress address = {
		kAudioHardwarePropertyProcessObjectList,
		kAudioObjectPropertyScopeGlobal,
		kAudioObjectPropertyElementMain
	};
	UInt32 size = 0;
	AudioObjectID *objects;
	OSStatus status;

	if (!out_objects || !out_count)
		return TINYAAC_ERR_INVALID_ARGUMENT;
	*out_objects = NULL;
	*out_count = 0;
	status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address,
		0, NULL, &size);
	if (status != noErr)
		return TINYAAC_ERR_BACKEND;
	if (!size)
		return TINYAAC_OK;
	objects = (AudioObjectID *)malloc(size);
	if (!objects)
		return TINYAAC_ERR_OUT_OF_MEMORY;
	status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address,
		0, NULL, &size, objects);
	if (status != noErr) {
		free(objects);
		return TINYAAC_ERR_BACKEND;
	}
	*out_objects = objects;
	*out_count = size / sizeof(*objects);
	return TINYAAC_OK;
}

static uint32_t tinyaac_macos_process_pid(AudioObjectID process)
{
	AudioObjectPropertyAddress address = {
		kAudioProcessPropertyPID,
		kAudioObjectPropertyScopeGlobal,
		kAudioObjectPropertyElementMain
	};
	pid_t pid = 0;
	UInt32 size = sizeof(pid);
	if (AudioObjectGetPropertyData(process, &address, 0, NULL, &size, &pid) != noErr || pid <= 0)
		return 0;
	return (uint32_t)pid;
}

static tinyaac_status tinyaac_platform_init(void)
{
	if (@available(macOS 14.2, *))
		return TINYAAC_OK;
	tinyaac_internal_set_error("macOS 14.2 or newer is required for Core Audio process taps");
	return TINYAAC_ERR_PLATFORM_UNAVAILABLE;
}

static void tinyaac_platform_shutdown(void) {}

static tinyaac_status tinyaac_platform_enumerate(tinyaac_app_list *list)
{
	AudioObjectID *objects = NULL;
	UInt32 count = 0;
	UInt32 index;
	tinyaac_status status;

	if (!list)
		return TINYAAC_ERR_INVALID_ARGUMENT;
	status = tinyaac_macos_process_objects(&objects, &count);
	if (status != TINYAAC_OK)
		return status;
	@autoreleasepool {
		for (index = 0; index < count; ++index) {
			uint32_t pid = tinyaac_macos_process_pid(objects[index]);
			NSRunningApplication *application;
			NSString *name;
			const char *display_name;
			char fallback_name[64];
			char fallback_identifier[64];
			if (!pid)
				continue;
			application = [NSRunningApplication runningApplicationWithProcessIdentifier:(pid_t)pid];
			name = application.localizedName;
			display_name = name ? name.UTF8String : NULL;
			if (!display_name) {
				snprintf(fallback_name, sizeof(fallback_name), "Process %u", pid);
				display_name = fallback_name;
			}
			snprintf(fallback_identifier, sizeof(fallback_identifier),
				"mac-process:%u", objects[index]);
			if (tinyaac_internal_append_app(list, display_name, fallback_identifier, pid) != TINYAAC_OK) {
				status = TINYAAC_ERR_OUT_OF_MEMORY;
				break;
			}
		}
	}
	free(objects);
	if (status != TINYAAC_OK)
		tinyaac_internal_set_error("Unable to allocate the macOS audio-process snapshot");
	return status;
}

struct tinyaac_macos_work {
	struct tinyaac_macos_work *next;
	tinyaac_audio_frame frame;
	float samples[1];
};

struct tinyaac_macos_capture {
	AudioObjectID tap;
	AudioObjectID aggregate_device;
	AudioDeviceIOProcID io_proc;
	AudioStreamBasicDescription format;
	pthread_t callback_thread;
	pthread_mutex_t queue_mutex;
	pthread_cond_t queue_ready;
	struct tinyaac_macos_work *queue_head;
	struct tinyaac_macos_work *queue_tail;
	int closing;
	int callback_thread_started;
	int device_started;
};

static void tinyaac_macos_enqueue(struct tinyaac_macos_capture *backend,
	struct tinyaac_macos_work *work)
{
	pthread_mutex_lock(&backend->queue_mutex);
	if (backend->closing) {
		pthread_mutex_unlock(&backend->queue_mutex);
		free(work);
		return;
	}
	if (backend->queue_tail)
		backend->queue_tail->next = work;
	else
		backend->queue_head = work;
	backend->queue_tail = work;
	pthread_cond_signal(&backend->queue_ready);
	pthread_mutex_unlock(&backend->queue_mutex);
}

static void *tinyaac_macos_callback_thread(void *data)
{
	tinyaac_capture *capture = (tinyaac_capture *)data;
	struct tinyaac_macos_capture *backend =
		(struct tinyaac_macos_capture *)capture->backend;
	for (;;) {
		struct tinyaac_macos_work *work;
		pthread_mutex_lock(&backend->queue_mutex);
		while (!backend->queue_head && !backend->closing)
			pthread_cond_wait(&backend->queue_ready, &backend->queue_mutex);
		if (!backend->queue_head && backend->closing) {
			pthread_mutex_unlock(&backend->queue_mutex);
			break;
		}
		work = backend->queue_head;
		backend->queue_head = work->next;
		if (!backend->queue_head)
			backend->queue_tail = NULL;
		pthread_mutex_unlock(&backend->queue_mutex);
		if (capture->on_audio)
			capture->on_audio(&work->frame, capture->user_data);
		free(work);
	}
	return NULL;
}

static OSStatus tinyaac_macos_io_proc(AudioObjectID device,
	const AudioTimeStamp *input_time, const AudioBufferList *input_data,
	const AudioTimeStamp *output_time, AudioBufferList *output_data,
	const AudioTimeStamp *output_time_2, void *client_data)
{
	struct tinyaac_macos_capture *backend =
		(struct tinyaac_macos_capture *)client_data;
	UInt32 buffer_index;
	UInt32 channels = 0;
	UInt32 frames = UINT32_MAX;
	size_t bytes;
	struct tinyaac_macos_work *work;
	(void)device;
	(void)output_time;
	(void)output_data;
	(void)output_time_2;
	if (!input_data || !input_data->mNumberBuffers || backend->closing)
		return noErr;
	for (buffer_index = 0; buffer_index < input_data->mNumberBuffers; ++buffer_index) {
		const AudioBuffer *buffer = &input_data->mBuffers[buffer_index];
		UInt32 buffer_channels = buffer->mNumberChannels;
		UInt32 buffer_frames;
		if (!buffer->mData || !buffer_channels)
			return noErr;
		buffer_frames = buffer->mDataByteSize / (buffer_channels * sizeof(float));
		if (buffer_frames < frames)
			frames = buffer_frames;
		channels += buffer_channels;
	}
	if (!channels || frames == UINT32_MAX || !frames)
		return noErr;
	bytes = (size_t)frames * channels * sizeof(float);
	work = (struct tinyaac_macos_work *)malloc(sizeof(*work) + bytes - sizeof(float));
	if (!work)
		return noErr;
	memset(work, 0, sizeof(*work));
	work->frame.samples = work->samples;
	work->frame.frame_count = frames;
	work->frame.channels = channels;
	work->frame.sample_rate = (uint32_t)backend->format.mSampleRate;
	work->frame.timestamp_ns = input_time ? AudioConvertHostTimeToNanos(input_time->mHostTime) : 0;
	if (input_data->mNumberBuffers == 1) {
		memcpy(work->samples, input_data->mBuffers[0].mData, bytes);
	} else {
		UInt32 frame_index;
		for (frame_index = 0; frame_index < frames; ++frame_index) {
			UInt32 output_channel = 0;
			for (buffer_index = 0; buffer_index < input_data->mNumberBuffers; ++buffer_index) {
				const AudioBuffer *buffer = &input_data->mBuffers[buffer_index];
				const float *source = (const float *)buffer->mData;
				UInt32 channel;
				for (channel = 0; channel < buffer->mNumberChannels; ++channel)
					work->samples[frame_index * channels + output_channel++] =
						source[frame_index * buffer->mNumberChannels + channel];
			}
		}
	}
	tinyaac_macos_enqueue(backend, work);
	return noErr;
}

static void tinyaac_macos_capture_cleanup(tinyaac_capture *capture,
	struct tinyaac_macos_capture *backend)
{
	struct tinyaac_macos_work *work;
	if (!backend)
		return;
	if (backend->device_started)
		AudioDeviceStop(backend->aggregate_device, backend->io_proc);
	if (backend->io_proc)
		AudioDeviceDestroyIOProcID(backend->aggregate_device, backend->io_proc);
	if (backend->aggregate_device != kAudioObjectUnknown)
		AudioHardwareDestroyAggregateDevice(backend->aggregate_device);
	if (backend->tap != kAudioObjectUnknown)
		AudioHardwareDestroyProcessTap(backend->tap);
	pthread_mutex_lock(&backend->queue_mutex);
	backend->closing = 1;
	pthread_cond_signal(&backend->queue_ready);
	pthread_mutex_unlock(&backend->queue_mutex);
	if (backend->callback_thread_started)
		pthread_join(backend->callback_thread, NULL);
	while ((work = backend->queue_head) != NULL) {
		backend->queue_head = work->next;
		free(work);
	}
	pthread_cond_destroy(&backend->queue_ready);
	pthread_mutex_destroy(&backend->queue_mutex);
	if (capture && capture->backend == backend)
		capture->backend = NULL;
	free(backend);
}

static tinyaac_status tinyaac_platform_capture_start(tinyaac_capture *capture)
{
	struct tinyaac_macos_capture *backend;
	char *end;
	unsigned long process_id;
	CATapDescription *tap_description;
	CFStringRef tap_uid = NULL;
	CFArrayRef tap_list;
	AudioObjectPropertyAddress address;
	UInt32 property_size;
	OSStatus result;
	NSDictionary *aggregate_properties;
	NSString *aggregate_uid;

	if (!capture || strncmp(capture->identifier, "mac-process:", 12) != 0)
		return TINYAAC_ERR_INVALID_ARGUMENT;
	process_id = strtoul(capture->identifier + 12, &end, 10);
	if (!*(capture->identifier + 12) || *end || process_id > UINT32_MAX)
		return TINYAAC_ERR_INVALID_ARGUMENT;
	backend = (struct tinyaac_macos_capture *)calloc(1, sizeof(*backend));
	if (!backend)
		return TINYAAC_ERR_OUT_OF_MEMORY;
	backend->tap = kAudioObjectUnknown;
	backend->aggregate_device = kAudioObjectUnknown;
	if (pthread_mutex_init(&backend->queue_mutex, NULL) ||
		pthread_cond_init(&backend->queue_ready, NULL)) {
		free(backend);
		return TINYAAC_ERR_BACKEND;
	}
	@autoreleasepool {
		tap_description = [[CATapDescription alloc] init];
		tap_description.name = @"tinyaac process tap";
		tap_description.processes = @[@((AudioObjectID)process_id)];
		tap_description.isPrivate = YES;
		tap_description.isMixdown = YES;
		tap_description.isMono = NO;
		result = AudioHardwareCreateProcessTap(tap_description, &backend->tap);
		if (result != noErr)
			goto failed;
		address.mSelector = kAudioTapPropertyUID;
		address.mScope = kAudioObjectPropertyScopeGlobal;
		address.mElement = kAudioObjectPropertyElementMain;
		property_size = sizeof(tap_uid);
		result = AudioObjectGetPropertyData(backend->tap, &address, 0, NULL,
			&property_size, &tap_uid);
		if (result != noErr || !tap_uid)
			goto failed;
		aggregate_uid = [NSUUID UUID].UUIDString;
		aggregate_properties = @{
			(__bridge NSString *)kAudioAggregateDeviceNameKey: @"tinyaac aggregate device",
			(__bridge NSString *)kAudioAggregateDeviceUIDKey: aggregate_uid,
			(__bridge NSString *)kAudioAggregateDeviceIsPrivateKey: @YES,
			(__bridge NSString *)kAudioAggregateDeviceTapAutoStartKey: @YES,
		};
		result = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggregate_properties,
			&backend->aggregate_device);
		if (result != noErr)
			goto failed;
		tap_list = CFArrayCreate(kCFAllocatorDefault, (const void **)&tap_uid, 1,
			&kCFTypeArrayCallBacks);
		if (!tap_list)
			goto failed;
		address.mSelector = kAudioAggregateDevicePropertyTapList;
		property_size = sizeof(tap_list);
		result = AudioObjectSetPropertyData(backend->aggregate_device, &address, 0,
			NULL, property_size, &tap_list);
		CFRelease(tap_list);
		if (result != noErr)
			goto failed;
		address.mSelector = kAudioDevicePropertyStreamFormat;
		address.mScope = kAudioDevicePropertyScopeInput;
		property_size = sizeof(backend->format);
		result = AudioObjectGetPropertyData(backend->aggregate_device, &address, 0,
			NULL, &property_size, &backend->format);
		if (result != noErr || backend->format.mFormatID != kAudioFormatLinearPCM ||
			!(backend->format.mFormatFlags & kAudioFormatFlagIsFloat) ||
			backend->format.mBitsPerChannel != 32)
			goto failed;
	}
	capture->backend = backend;
	if (pthread_create(&backend->callback_thread, NULL,
		tinyaac_macos_callback_thread, capture) != 0)
		goto failed;
	backend->callback_thread_started = 1;
	result = AudioDeviceCreateIOProcID(backend->aggregate_device, tinyaac_macos_io_proc,
		backend, &backend->io_proc);
	if (result != noErr)
		goto failed;
	result = AudioDeviceStart(backend->aggregate_device, backend->io_proc);
	if (result != noErr)
		goto failed;
	backend->device_started = 1;
	return TINYAAC_OK;

failed:
	tinyaac_internal_set_error("Unable to create a Core Audio process tap; verify macOS permission and NSAudioCaptureUsageDescription");
	tinyaac_macos_capture_cleanup(capture, backend);
	return TINYAAC_ERR_BACKEND;
}

static tinyaac_status tinyaac_platform_capture_stop(tinyaac_capture *capture)
{
	if (!capture || !capture->backend)
		return TINYAAC_ERR_INVALID_STATE;
	tinyaac_macos_capture_cleanup(capture,
		(struct tinyaac_macos_capture *)capture->backend);
	return TINYAAC_OK;
}

static void tinyaac_platform_capture_destroy(tinyaac_capture *capture)
{
	if (capture && capture->backend)
		tinyaac_macos_capture_cleanup(capture,
			(struct tinyaac_macos_capture *)capture->backend);
}

#endif /* __APPLE__ */
/* End tinyaac_macos.h */

/* Begin tinyaac_unsupported.h */
#if !defined(_WIN32) && !defined(__linux__) && !defined(__APPLE__)

static tinyaac_status tinyaac_platform_init(void)
{
	tinyaac_internal_set_error("tinyaac supports Windows, Linux/PipeWire, and macOS only");
	return TINYAAC_ERR_PLATFORM_UNAVAILABLE;
}

static void tinyaac_platform_shutdown(void) {}

static tinyaac_status tinyaac_platform_enumerate(tinyaac_app_list *list)
{
	(void)list;
	return TINYAAC_ERR_PLATFORM_UNAVAILABLE;
}

static tinyaac_status tinyaac_platform_capture_start(tinyaac_capture *capture)
{
	(void)capture;
	return TINYAAC_ERR_PLATFORM_UNAVAILABLE;
}

static tinyaac_status tinyaac_platform_capture_stop(tinyaac_capture *capture)
{
	(void)capture;
	return TINYAAC_OK;
}

static void tinyaac_platform_capture_destroy(tinyaac_capture *capture)
{
	(void)capture;
}

#endif
/* End tinyaac_unsupported.h */

/* Begin tinyaac_common.h */
#ifdef TINYAAC_IMPLEMENTATION
#ifndef TINYAAC_COMMON_IMPLEMENTATION_INCLUDED
#define TINYAAC_COMMON_IMPLEMENTATION_INCLUDED

static unsigned int tinyaac_internal_init_count;
static char tinyaac_internal_error[256];

static void tinyaac_internal_set_error(const char *message)
{
	size_t length = message ? strlen(message) : 0;
	if (length >= sizeof(tinyaac_internal_error))
		length = sizeof(tinyaac_internal_error) - 1;
	if (length)
		memcpy(tinyaac_internal_error, message, length);
	tinyaac_internal_error[length] = '\0';
}

tinyaac_status tinyaac_init(void)
{
	tinyaac_status status;
	if (tinyaac_internal_init_count++)
		return TINYAAC_OK;
	status = tinyaac_platform_init();
	if (status != TINYAAC_OK) {
		tinyaac_internal_init_count = 0;
		return status;
	}
	tinyaac_internal_set_error("");
	return TINYAAC_OK;
}

void tinyaac_shutdown(void)
{
	if (!tinyaac_internal_init_count)
		return;
	if (!--tinyaac_internal_init_count)
		tinyaac_platform_shutdown();
}

const char *tinyaac_last_error(void)
{
	return tinyaac_internal_error;
}

tinyaac_status tinyaac_app_list_create(tinyaac_app_list **out_list)
{
	tinyaac_app_list *list;
	tinyaac_status status;
	if (!out_list)
		return TINYAAC_ERR_INVALID_ARGUMENT;
	*out_list = NULL;
	if (!tinyaac_internal_init_count)
		return TINYAAC_ERR_INVALID_STATE;
	list = (tinyaac_app_list *)calloc(1, sizeof(*list));
	if (!list)
		return TINYAAC_ERR_OUT_OF_MEMORY;
	status = tinyaac_platform_enumerate(list);
	if (status != TINYAAC_OK) {
		tinyaac_app_list_destroy(list);
		return status;
	}
	*out_list = list;
	return TINYAAC_OK;
}

size_t tinyaac_app_list_count(const tinyaac_app_list *list)
{
	return list ? list->count : 0;
}

const tinyaac_app_info *tinyaac_app_list_get(const tinyaac_app_list *list,
	size_t index)
{
	if (!list || index >= list->count)
		return NULL;
	return &list->apps[index];
}

void tinyaac_app_list_destroy(tinyaac_app_list *list)
{
	size_t index;
	if (!list)
		return;
	for (index = 0; index < list->count; ++index) {
		free((void *)list->apps[index].display_name);
		free((void *)list->apps[index].identifier);
	}
	free(list->apps);
	free(list);
}

tinyaac_status tinyaac_capture_create(const tinyaac_app_list *list, size_t index,
	tinyaac_capture **out_capture)
{
	tinyaac_capture *capture;
	if (!out_capture || !list || index >= list->count)
		return TINYAAC_ERR_INVALID_ARGUMENT;
	*out_capture = NULL;
	if (!tinyaac_internal_init_count)
		return TINYAAC_ERR_INVALID_STATE;
	capture = (tinyaac_capture *)calloc(1, sizeof(*capture));
	if (!capture)
		return TINYAAC_ERR_OUT_OF_MEMORY;
	capture->identifier = tinyaac_internal_strdup(list->apps[index].identifier);
	if (!capture->identifier) {
		free(capture);
		return TINYAAC_ERR_OUT_OF_MEMORY;
	}
	capture->process_id = list->apps[index].process_id;
	*out_capture = capture;
	return TINYAAC_OK;
}

tinyaac_status tinyaac_capture_set_callbacks(tinyaac_capture *capture,
	tinyaac_audio_callback on_audio, tinyaac_event_callback on_event,
	void *user_data)
{
	if (!capture || capture->started)
		return TINYAAC_ERR_INVALID_STATE;
	capture->on_audio = on_audio;
	capture->on_event = on_event;
	capture->user_data = user_data;
	return TINYAAC_OK;
}

tinyaac_status tinyaac_capture_start(tinyaac_capture *capture)
{
	tinyaac_status status;
	if (!capture || capture->started || !capture->on_audio)
		return TINYAAC_ERR_INVALID_STATE;
	status = tinyaac_platform_capture_start(capture);
	if (status == TINYAAC_OK) {
		capture->started = 1;
		if (capture->on_event)
			capture->on_event(TINYAAC_EVENT_STARTED, TINYAAC_OK, "", capture->user_data);
	}
	return status;
}

tinyaac_status tinyaac_capture_stop(tinyaac_capture *capture)
{
	tinyaac_status status;
	if (!capture || !capture->started)
		return TINYAAC_ERR_INVALID_STATE;
	status = tinyaac_platform_capture_stop(capture);
	capture->started = 0;
	if (capture->on_event)
		capture->on_event(TINYAAC_EVENT_STOPPED, status, "", capture->user_data);
	return status;
}

void tinyaac_capture_destroy(tinyaac_capture *capture)
{
	if (!capture)
		return;
	if (capture->started)
		tinyaac_capture_stop(capture);
	tinyaac_platform_capture_destroy(capture);
	free(capture->identifier);
	free(capture);
}

#endif /* TINYAAC_COMMON_IMPLEMENTATION_INCLUDED */
#endif /* TINYAAC_IMPLEMENTATION */
/* End tinyaac_common.h */
#endif /* TINYAAC_IMPLEMENTATION */
