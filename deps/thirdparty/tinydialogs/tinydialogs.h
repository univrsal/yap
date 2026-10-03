/*
   tinydialogs.h -- small native file dialogs and message boxes for C

   Define TINYDIALOGS_IMPLEMENTATION in exactly one translation unit before
   including this file to compile the implementation.

   SPDX-License-Identifier: MIT OR Unlicense
*/
#ifndef TINYDIALOGS_H_INCLUDED
#define TINYDIALOGS_H_INCLUDED

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TINYDIALOGS_VERSION_MAJOR 0
#define TINYDIALOGS_VERSION_MINOR 1
#define TINYDIALOGS_VERSION_PATCH 0

typedef enum td_status {
    TD_STATUS_OK = 0,
    TD_STATUS_CANCELLED,
    TD_STATUS_UNAVAILABLE,
    TD_STATUS_INVALID_ARGUMENT,
    TD_STATUS_FAILED
} td_status;

typedef enum td_buttons {
    TD_BUTTONS_OK = 0,
    TD_BUTTONS_OK_CANCEL,
    TD_BUTTONS_YES_NO,
    TD_BUTTONS_YES_NO_CANCEL
} td_buttons;

typedef enum td_icon {
    TD_ICON_NONE = 0,
    TD_ICON_INFO,
    TD_ICON_WARNING,
    TD_ICON_ERROR,
    TD_ICON_QUESTION
} td_icon;

typedef enum td_button {
    TD_BUTTON_NONE = 0,
    TD_BUTTON_OK,
    TD_BUTTON_CANCEL,
    TD_BUTTON_YES,
    TD_BUTTON_NO
} td_button;

/* Semicolon-separated glob patterns, for example: "*.png;*.jpg". */
typedef struct td_filter {
    const char *label;
    const char *patterns;
} td_filter;

typedef struct td_dialog_options {
    const char *title;
    const char *initial_path;
    const td_filter *filters;
    size_t filter_count;
} td_dialog_options;

typedef struct td_path_list {
    char **items;
    size_t count;
} td_path_list;

/* All text accepted and returned by this API is UTF-8. A cancelled dialog is
   reported as TD_STATUS_CANCELLED and is not an error. */
const char *td_last_error(void);
void td_path_list_free(td_path_list *paths);
td_status td_open_file(const td_dialog_options *options, td_path_list *result);
td_status td_open_files(const td_dialog_options *options, td_path_list *result);
td_status td_pick_folder(const td_dialog_options *options, td_path_list *result);
td_status td_save_file(const td_dialog_options *options, td_path_list *result);
td_status td_message_box(const char *title, const char *text, td_buttons buttons,
                         td_icon icon, td_button *pressed);

#ifdef __cplusplus
} /* extern "C" */
#endif
#endif /* TINYDIALOGS_H_INCLUDED */

#ifdef TINYDIALOGS_IMPLEMENTATION
#ifndef TINYDIALOGS_IMPLEMENTATION_INCLUDED
#define TINYDIALOGS_IMPLEMENTATION_INCLUDED

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_MSC_VER)
#define TD_THREAD_LOCAL __declspec(thread)
#else
#define TD_THREAD_LOCAL _Thread_local
#endif

static TD_THREAD_LOCAL char td_error[512];

static void td_set_error(const char *format, ...) {
    va_list args;
    va_start(args, format);
    vsnprintf(td_error, sizeof(td_error), format, args);
    va_end(args);
}

const char *td_last_error(void) { return td_error; }

static void td_clear_result(td_path_list *paths) {
    if (paths) { paths->items = NULL; paths->count = 0; }
}

void td_path_list_free(td_path_list *paths) {
    size_t index;
    if (!paths) return;
    for (index = 0; index < paths->count; ++index) free(paths->items[index]);
    free(paths->items);
    td_clear_result(paths);
}

static char *td_strdup(const char *source) {
    size_t length;
    char *copy;
    if (!source) return NULL;
    length = strlen(source) + 1;
    copy = (char *)malloc(length);
    if (copy) memcpy(copy, source, length);
    return copy;
}

static int td_append_path(td_path_list *paths, const char *path) {
    char **items;
    char *copy;
    if (!paths || !path || !*path) return 0;
    copy = td_strdup(path);
    if (!copy) return 0;
    items = (char **)realloc(paths->items, (paths->count + 1) * sizeof(*items));
    if (!items) { free(copy); return 0; }
    paths->items = items;
    paths->items[paths->count++] = copy;
    return 1;
}

static int td_validate(const td_dialog_options *options, td_path_list *result) {
    size_t index;
    td_clear_result(result);
    td_error[0] = '\0';
    if (!result) { td_set_error("result must not be null"); return 0; }
    if (!options) return 1;
    if (options->filter_count && !options->filters) {
        td_set_error("filters is null while filter_count is non-zero"); return 0;
    }
    for (index = 0; index < options->filter_count; ++index) {
        if (!options->filters[index].patterns || !*options->filters[index].patterns) {
            td_set_error("filter %lu has no patterns", (unsigned long)index); return 0;
        }
    }
    return 1;
}

#if defined(_WIN32)

#define COBJMACROS
#include <windows.h>
#include <shobjidl.h>
#include <shlwapi.h>

static char *td_utf8_from_wide(const wchar_t *source) {
    int bytes;
    char *result;
    if (!source) return NULL;
    bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, source, -1, NULL, 0, NULL, NULL);
    if (!bytes) return NULL;
    result = (char *)malloc((size_t)bytes);
    if (result) WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, source, -1, result, bytes, NULL, NULL);
    return result;
}

static wchar_t *td_wide_from_utf8(const char *source) {
    int chars;
    wchar_t *result;
    if (!source) return NULL;
    chars = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, source, -1, NULL, 0);
    if (!chars) return NULL;
    result = (wchar_t *)malloc((size_t)chars * sizeof(*result));
    if (result) MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, source, -1, result, chars);
    return result;
}

static COMDLG_FILTERSPEC *td_windows_filters(const td_dialog_options *options) {
    COMDLG_FILTERSPEC *specs;
    size_t index;
    if (!options || !options->filter_count) return NULL;
    specs = (COMDLG_FILTERSPEC *)calloc(options->filter_count, sizeof(*specs));
    if (!specs) return NULL;
    for (index = 0; index < options->filter_count; ++index) {
        specs[index].pszName = td_wide_from_utf8(options->filters[index].label ? options->filters[index].label : options->filters[index].patterns);
        specs[index].pszSpec = td_wide_from_utf8(options->filters[index].patterns);
        if (!specs[index].pszName || !specs[index].pszSpec) {
            size_t cleanup;
            for (cleanup = 0; cleanup <= index; ++cleanup) { free((void *)specs[cleanup].pszName); free((void *)specs[cleanup].pszSpec); }
            free(specs);
            return NULL;
        }
    }
    return specs;
}

static void td_windows_free_filters(COMDLG_FILTERSPEC *specs, size_t count) {
    size_t index;
    for (index = 0; specs && index < count; ++index) { free((void *)specs[index].pszName); free((void *)specs[index].pszSpec); }
    free(specs);
}

static td_status td_windows_file_dialog(const td_dialog_options *options, int mode, td_path_list *result) {
    IFileDialog *dialog = NULL;
    IShellItemArray *array = NULL;
    IShellItem *item = NULL;
    FILEOPENDIALOGOPTIONS flags;
    HRESULT hr;
    int com_started = 0;
    COMDLG_FILTERSPEC *filters = NULL;
    td_status status = TD_STATUS_FAILED;
    if (!td_validate(options, result)) return TD_STATUS_INVALID_ARGUMENT;
    hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    if (SUCCEEDED(hr)) com_started = 1;
    else if (hr != RPC_E_CHANGED_MODE) { td_set_error("CoInitializeEx failed (0x%08lx)", (unsigned long)hr); return TD_STATUS_FAILED; }
    hr = mode == 3 ? CoCreateInstance(&CLSID_FileSaveDialog, NULL, CLSCTX_INPROC_SERVER, &IID_IFileSaveDialog, (void **)&dialog)
                   : CoCreateInstance(&CLSID_FileOpenDialog, NULL, CLSCTX_INPROC_SERVER, &IID_IFileOpenDialog, (void **)&dialog);
    if (FAILED(hr)) { td_set_error("creating the native file dialog failed (0x%08lx)", (unsigned long)hr); goto done; }
    IFileDialog_GetOptions(dialog, &flags);
    if (mode == 1) flags |= FOS_ALLOWMULTISELECT;
    if (mode == 2) flags |= FOS_PICKFOLDERS;
    IFileDialog_SetOptions(dialog, flags);
    if (options && options->title) { wchar_t *title = td_wide_from_utf8(options->title); if (title) { IFileDialog_SetTitle(dialog, title); free(title); } }
    filters = td_windows_filters(options);
    if (options && options->filter_count && !filters) { td_set_error("could not convert file filters to UTF-16"); goto done; }
    if (filters) IFileDialog_SetFileTypes(dialog, (UINT)options->filter_count, filters);
    hr = IFileDialog_Show(dialog, NULL);
    if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) { status = TD_STATUS_CANCELLED; goto done; }
    if (FAILED(hr)) { td_set_error("showing the native file dialog failed (0x%08lx)", (unsigned long)hr); goto done; }
    if (mode == 1) {
        DWORD count = 0, index;
        hr = IFileOpenDialog_GetResults((IFileOpenDialog *)dialog, &array);
        if (FAILED(hr)) goto done;
        IShellItemArray_GetCount(array, &count);
        for (index = 0; index < count; ++index) {
            PWSTR path = NULL;
            IShellItemArray_GetItemAt(array, index, &item);
            if (item && SUCCEEDED(IShellItem_GetDisplayName(item, SIGDN_FILESYSPATH, &path))) {
                char *utf8 = td_utf8_from_wide(path);
                if (utf8) { td_append_path(result, utf8); free(utf8); }
                CoTaskMemFree(path);
            }
            if (item) { IShellItem_Release(item); item = NULL; }
        }
    } else {
        PWSTR path = NULL;
        hr = IFileDialog_GetResult(dialog, &item);
        if (SUCCEEDED(hr) && SUCCEEDED(IShellItem_GetDisplayName(item, SIGDN_FILESYSPATH, &path))) {
            char *utf8 = td_utf8_from_wide(path);
            if (utf8) { td_append_path(result, utf8); free(utf8); }
            CoTaskMemFree(path);
        }
    }
    status = result->count ? TD_STATUS_OK : TD_STATUS_FAILED;
    if (status != TD_STATUS_OK) td_set_error("native dialog returned no path");
done:
    td_windows_free_filters(filters, options ? options->filter_count : 0);
    if (item) IShellItem_Release(item);
    if (array) IShellItemArray_Release(array);
    if (dialog) IFileDialog_Release(dialog);
    if (com_started) CoUninitialize();
    return status;
}

td_status td_open_file(const td_dialog_options *options, td_path_list *result) { return td_windows_file_dialog(options, 0, result); }
td_status td_open_files(const td_dialog_options *options, td_path_list *result) { return td_windows_file_dialog(options, 1, result); }
td_status td_pick_folder(const td_dialog_options *options, td_path_list *result) { return td_windows_file_dialog(options, 2, result); }
td_status td_save_file(const td_dialog_options *options, td_path_list *result) { return td_windows_file_dialog(options, 3, result); }

td_status td_message_box(const char *title, const char *text, td_buttons buttons, td_icon icon, td_button *pressed) {
    UINT type = 0; int answer; wchar_t *wide_title; wchar_t *wide_text;
    if (!text || !pressed) return TD_STATUS_INVALID_ARGUMENT;
    type = buttons == TD_BUTTONS_OK_CANCEL ? MB_OKCANCEL : buttons == TD_BUTTONS_YES_NO ? MB_YESNO : buttons == TD_BUTTONS_YES_NO_CANCEL ? MB_YESNOCANCEL : MB_OK;
    type |= icon == TD_ICON_INFO ? MB_ICONINFORMATION : icon == TD_ICON_WARNING ? MB_ICONWARNING : icon == TD_ICON_ERROR ? MB_ICONERROR : icon == TD_ICON_QUESTION ? MB_ICONQUESTION : 0;
    wide_title = td_wide_from_utf8(title ? title : ""); wide_text = td_wide_from_utf8(text);
    if (!wide_text) { free(wide_title); td_set_error("message text is not valid UTF-8"); return TD_STATUS_INVALID_ARGUMENT; }
    answer = MessageBoxW(NULL, wide_text, wide_title, type); free(wide_title); free(wide_text);
    *pressed = answer == IDOK ? TD_BUTTON_OK : answer == IDCANCEL ? TD_BUTTON_CANCEL : answer == IDYES ? TD_BUTTON_YES : TD_BUTTON_NO;
    return TD_STATUS_OK;
}

#elif defined(__APPLE__)

#import <Cocoa/Cocoa.h>

static td_status td_macos_file_dialog(const td_dialog_options *options, int mode, td_path_list *result) {
    NSAutoreleasePool *pool; NSOpenPanel *open_panel; NSSavePanel *save_panel; NSInteger response; NSArray *urls; NSUInteger index;
    NSMutableArray *extensions = nil;
    if (!td_validate(options, result)) return TD_STATUS_INVALID_ARGUMENT;
    pool = [[NSAutoreleasePool alloc] init];
    if (options && options->filter_count) {
        extensions = [NSMutableArray array];
        for (index = 0; index < options->filter_count; ++index) {
            NSArray *patterns = [[NSString stringWithUTF8String:options->filters[index].patterns] componentsSeparatedByString:@";"];
            for (NSString *pattern in patterns) {
                if ([pattern hasPrefix:@"*."] && [pattern length] > 2) [extensions addObject:[pattern substringFromIndex:2]];
            }
        }
    }
    if (mode == 3) {
        save_panel = [NSSavePanel savePanel];
        if (options && options->title) [save_panel setTitle:[NSString stringWithUTF8String:options->title]];
        if ([extensions count]) [save_panel setAllowedFileTypes:extensions];
        response = [save_panel runModal];
        if (response == NSModalResponseOK) td_append_path(result, [[[save_panel URL] path] UTF8String]);
    } else {
        open_panel = [NSOpenPanel openPanel];
        [open_panel setCanChooseFiles:mode != 2]; [open_panel setCanChooseDirectories:mode == 2]; [open_panel setAllowsMultipleSelection:mode == 1];
        if (options && options->title) [open_panel setTitle:[NSString stringWithUTF8String:options->title]];
        if ([extensions count]) [open_panel setAllowedFileTypes:extensions];
        response = [open_panel runModal];
        if (response == NSModalResponseOK) { urls = [open_panel URLs]; for (index = 0; index < [urls count]; ++index) td_append_path(result, [[urls objectAtIndex:index] path].UTF8String); }
    }
    [pool drain];
    return result->count ? TD_STATUS_OK : TD_STATUS_CANCELLED;
}
td_status td_open_file(const td_dialog_options *options, td_path_list *result) { return td_macos_file_dialog(options, 0, result); }
td_status td_open_files(const td_dialog_options *options, td_path_list *result) { return td_macos_file_dialog(options, 1, result); }
td_status td_pick_folder(const td_dialog_options *options, td_path_list *result) { return td_macos_file_dialog(options, 2, result); }
td_status td_save_file(const td_dialog_options *options, td_path_list *result) { return td_macos_file_dialog(options, 3, result); }
td_status td_message_box(const char *title, const char *text, td_buttons buttons, td_icon icon, td_button *pressed) {
    NSAutoreleasePool *pool; NSAlert *alert; NSModalResponse response;
    if (!text || !pressed) return TD_STATUS_INVALID_ARGUMENT;
    pool = [[NSAutoreleasePool alloc] init]; alert = [[NSAlert alloc] init]; [alert setMessageText:[NSString stringWithUTF8String:title ? title : ""]]; [alert setInformativeText:[NSString stringWithUTF8String:text]];
    [alert addButtonWithTitle:buttons == TD_BUTTONS_YES_NO || buttons == TD_BUTTONS_YES_NO_CANCEL ? @"Yes" : @"OK"];
    if (buttons != TD_BUTTONS_OK) [alert addButtonWithTitle:buttons == TD_BUTTONS_OK_CANCEL ? @"Cancel" : @"No"];
    if (buttons == TD_BUTTONS_YES_NO_CANCEL) [alert addButtonWithTitle:@"Cancel"];
    response = [alert runModal]; [alert release]; [pool drain];
    *pressed = response == NSAlertFirstButtonReturn ? (buttons == TD_BUTTONS_YES_NO || buttons == TD_BUTTONS_YES_NO_CANCEL ? TD_BUTTON_YES : TD_BUTTON_OK) : response == NSAlertSecondButtonReturn ? (buttons == TD_BUTTONS_OK_CANCEL ? TD_BUTTON_CANCEL : TD_BUTTON_NO) : TD_BUTTON_CANCEL;
    (void)icon; return TD_STATUS_OK;
}

#else

#include <sys/wait.h>

static char *td_shell_quote(const char *text) {
    size_t length = 3, index; char *out, *cursor;
    if (!text) return td_strdup("''");
    for (index = 0; text[index]; ++index) length += text[index] == '\'' ? 4 : 1;
    out = (char *)malloc(length); if (!out) return NULL;
    cursor = out; *cursor++ = '\'';
    for (index = 0; text[index]; ++index) { if (text[index] == '\'') { memcpy(cursor, "'\\''", 4); cursor += 4; } else *cursor++ = text[index]; }
    *cursor++ = '\''; *cursor = '\0'; return out;
}

static int td_command_exists(const char *command) {
    char line[128]; FILE *pipe;
    snprintf(line, sizeof(line), "command -v %s >/dev/null 2>&1", command);
    pipe = popen(line, "r"); if (!pipe) return 0; return pclose(pipe) == 0;
}

static char *td_zenity_filters(const td_dialog_options *options) {
    char *result = td_strdup("");
    size_t index;
    if (!result || !options) return result;
    for (index = 0; index < options->filter_count; ++index) {
        const char *label = options->filters[index].label ? options->filters[index].label : options->filters[index].patterns;
        char *description = (char *)malloc(strlen(label) + strlen(options->filters[index].patterns) + 4);
        char *quoted, *next;
        if (!description) { free(result); return NULL; }
        snprintf(description, strlen(label) + strlen(options->filters[index].patterns) + 4, "%s | %s", label, options->filters[index].patterns);
        for (char *cursor = description; *cursor; ++cursor) if (*cursor == ';') *cursor = ' ';
        quoted = td_shell_quote(description);
        free(description);
        if (!quoted) { free(result); return NULL; }
        next = (char *)realloc(result, strlen(result) + strlen(quoted) + 17);
        if (!next) { free(quoted); free(result); return NULL; }
        result = next;
        strcat(result, " --file-filter=");
        strcat(result, quoted);
        free(quoted);
    }
    return result;
}

static td_status td_linux_file_dialog(const td_dialog_options *options, int mode, td_path_list *result) {
    const char *tool; char *title = NULL, *initial = NULL, *filters = NULL, *command = NULL; FILE *pipe; char line[4096]; int exit_code;
    if (!td_validate(options, result)) return TD_STATUS_INVALID_ARGUMENT;
    tool = td_command_exists("zenity") ? "zenity" : td_command_exists("kdialog") ? "kdialog" : NULL;
    if (!tool) { td_set_error("no supported Linux dialog backend found (install xdg-desktop-portal, zenity, or kdialog)"); return TD_STATUS_UNAVAILABLE; }
    title = td_shell_quote(options && options->title ? options->title : "Select a path");
    initial = td_shell_quote(options && options->initial_path ? options->initial_path : "");
    filters = td_zenity_filters(options);
    if (!title || !initial || !filters) { free(title); free(initial); free(filters); td_set_error("out of memory"); return TD_STATUS_FAILED; }
    if (strcmp(tool, "zenity") == 0) {
        const char *kind = mode == 3 ? "--file-selection --save --confirm-overwrite" : "--file-selection";
        command = (char *)malloc(strlen(title) + strlen(initial) + strlen(filters) + 256);
        if (command) snprintf(command, strlen(title) + strlen(initial) + strlen(filters) + 256, "zenity %s --title=%s --filename=%s%s%s%s 2>/dev/null", kind, title, initial, mode == 1 ? " --multiple --separator='\n'" : "", mode == 2 ? " --directory" : "", filters);
    } else {
        const char *kind = mode == 3 ? "--getsavefilename" : mode == 2 ? "--getexistingdirectory" : mode == 1 ? "--getopenfilename --multiple --separate-output" : "--getopenfilename";
        command = (char *)malloc(strlen(title) + strlen(initial) + 256);
        if (command) snprintf(command, strlen(title) + strlen(initial) + 256, "kdialog %s %s --title %s 2>/dev/null", kind, initial, title);
    }
    free(title); free(initial); free(filters);
    if (!command) { td_set_error("out of memory"); return TD_STATUS_FAILED; }
    pipe = popen(command, "r"); free(command);
    if (!pipe) { td_set_error("could not start Linux dialog backend"); return TD_STATUS_FAILED; }
    while (fgets(line, sizeof(line), pipe)) { size_t len = strlen(line); while (len && (line[len - 1] == '\n' || line[len - 1] == '\r')) line[--len] = '\0'; if (len && !td_append_path(result, line)) { pclose(pipe); td_path_list_free(result); td_set_error("out of memory"); return TD_STATUS_FAILED; } }
    exit_code = pclose(pipe);
    if (result->count) return TD_STATUS_OK;
    if (WIFEXITED(exit_code) && WEXITSTATUS(exit_code) == 1) return TD_STATUS_CANCELLED;
    td_set_error("Linux dialog backend failed"); return TD_STATUS_FAILED;
}
td_status td_open_file(const td_dialog_options *options, td_path_list *result) { return td_linux_file_dialog(options, 0, result); }
td_status td_open_files(const td_dialog_options *options, td_path_list *result) { return td_linux_file_dialog(options, 1, result); }
td_status td_pick_folder(const td_dialog_options *options, td_path_list *result) { return td_linux_file_dialog(options, 2, result); }
td_status td_save_file(const td_dialog_options *options, td_path_list *result) { return td_linux_file_dialog(options, 3, result); }
td_status td_message_box(const char *title, const char *text, td_buttons buttons, td_icon icon, td_button *pressed) {
    char *quoted_title, *quoted_text, *command; FILE *pipe; int status;
    if (!text || !pressed) return TD_STATUS_INVALID_ARGUMENT;
    if (!td_command_exists("zenity")) { td_set_error("message boxes require Zenity on this Linux build"); return TD_STATUS_UNAVAILABLE; }
    quoted_title = td_shell_quote(title ? title : "Message"); quoted_text = td_shell_quote(text);
    if (!quoted_title || !quoted_text) { free(quoted_title); free(quoted_text); return TD_STATUS_FAILED; }
    command = (char *)malloc(strlen(quoted_title) + strlen(quoted_text) + 160);
    if (!command) { free(quoted_title); free(quoted_text); return TD_STATUS_FAILED; }
    snprintf(command, strlen(quoted_title) + strlen(quoted_text) + 160, "zenity --%s --title=%s --text=%s 2>/dev/null", buttons == TD_BUTTONS_OK ? "info" : "question", quoted_title, quoted_text);
    free(quoted_title); free(quoted_text); pipe = popen(command, "r"); free(command); if (!pipe) return TD_STATUS_FAILED; status = pclose(pipe);
    if (buttons == TD_BUTTONS_OK) *pressed = TD_BUTTON_OK; else *pressed = WIFEXITED(status) && WEXITSTATUS(status) == 0 ? (buttons == TD_BUTTONS_YES_NO || buttons == TD_BUTTONS_YES_NO_CANCEL ? TD_BUTTON_YES : TD_BUTTON_OK) : (buttons == TD_BUTTONS_YES_NO || buttons == TD_BUTTONS_YES_NO_CANCEL ? TD_BUTTON_NO : TD_BUTTON_CANCEL);
    (void)icon; return TD_STATUS_OK;
}
#endif
#endif /* TINYDIALOGS_IMPLEMENTATION_INCLUDED */
#endif /* TINYDIALOGS_IMPLEMENTATION */
