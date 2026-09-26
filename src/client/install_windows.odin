package client

import "core:os"
import "core:strings"
import win "core:sys/windows"

/*
Installing on Windows (see ui_install_native.odin): a shortcut in the
user's Start menu, which is also what makes yap searchable from it. The
shortcut takes its icon from the .exe (see build.bat).

Shortcuts are only written and read through the shell's IShellLink,
which core:sys/windows doesn't declare, so the parts of it used here are.
*/

INSTALL_DESCRIPTION :: "Adds yap to your Start menu, pointing at this copy of yap; nothing is copied or moved. Uninstall removes it again."

@(private = "file")
CLSID_ShellLink := win.GUID{0x00021401, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}
@(private = "file")
IID_IShellLinkW := win.GUID{0x000214F9, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}
@(private = "file")
IID_IPersistFile := win.GUID{0x0000010B, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}

@(private = "file")
IShellLinkW :: struct {
	using vtable: ^IShellLinkW_VTable,
}

// In the interface's order; only the ones used have a real type.
@(private = "file")
IShellLinkW_VTable :: struct {
	using iunknown:      win.IUnknown_VTable,
	GetPath:             proc "system" (this: ^IShellLinkW, file: win.LPWSTR, cch: i32, fd: rawptr, flags: win.DWORD) -> win.HRESULT,
	GetIDList:           rawptr,
	SetIDList:           rawptr,
	GetDescription:      rawptr,
	SetDescription:      proc "system" (this: ^IShellLinkW, name: win.LPCWSTR) -> win.HRESULT,
	GetWorkingDirectory: rawptr,
	SetWorkingDirectory: proc "system" (this: ^IShellLinkW, dir: win.LPCWSTR) -> win.HRESULT,
	GetArguments:        rawptr,
	SetArguments:        rawptr,
	GetHotkey:           rawptr,
	SetHotkey:           rawptr,
	GetShowCmd:          rawptr,
	SetShowCmd:          rawptr,
	GetIconLocation:     rawptr,
	SetIconLocation:     proc "system" (this: ^IShellLinkW, path: win.LPCWSTR, icon: i32) -> win.HRESULT,
	SetRelativePath:     rawptr,
	Resolve:             rawptr,
	SetPath:             proc "system" (this: ^IShellLinkW, file: win.LPCWSTR) -> win.HRESULT,
}

@(private = "file")
IPersistFile :: struct {
	using vtable: ^IPersistFile_VTable,
}

@(private = "file")
IPersistFile_VTable :: struct {
	using iunknown: win.IUnknown_VTable,
	GetClassID:     rawptr,
	IsDirty:        rawptr,
	Load:           proc "system" (this: ^IPersistFile, file: win.LPCWSTR, mode: win.DWORD) -> win.HRESULT,
	Save:           proc "system" (this: ^IPersistFile, file: win.LPCWSTR, remember: win.BOOL) -> win.HRESULT,
	SaveCompleted:  rawptr,
	GetCurFile:     rawptr,
}

// shortcut_path is the shortcut's place in the Start menu, in the temp
// allocator.
@(private = "file")
shortcut_path :: proc() -> (path: string, ok: bool) {
	dir: win.LPWSTR
	folder := win.FOLDERID_Programs
	if win.FAILED(win.SHGetKnownFolderPath(&folder, 0, nil, &dir)) {
		return
	}
	defer win.CoTaskMemFree(dir)
	programs, err := win.wstring_to_utf8(win.wstring(dir), -1, context.temp_allocator)
	if err != nil {
		return
	}
	path, _ = os.join_path({programs, "Yap.lnk"}, context.temp_allocator)
	return path, true
}

// Shell_Link is a shell link object and the file interface of it.
@(private = "file")
Shell_Link :: struct {
	link: ^IShellLinkW,
	file: ^IPersistFile,
	com:  bool, // whether shell_link_close has COM to uninitialize
}

// shell_link_open makes a Shell_Link, setting COM up on this thread for
// it if it isn't already.
@(private = "file")
shell_link_open :: proc() -> (s: Shell_Link, ok: bool) {
	s.com = win.SUCCEEDED(win.CoInitializeEx(nil, .APARTMENTTHREADED))
	if win.FAILED(
		win.CoCreateInstance(&CLSID_ShellLink, nil, win.CLSCTX_INPROC_SERVER, &IID_IShellLinkW, (^rawptr)(&s.link)),
	) {
		s.link = nil
		shell_link_close(&s)
		return
	}
	if win.FAILED((^win.IUnknown)(s.link)->QueryInterface(&IID_IPersistFile, (^rawptr)(&s.file))) {
		s.file = nil
		shell_link_close(&s)
		return
	}
	return s, true
}

@(private = "file")
shell_link_close :: proc(s: ^Shell_Link) {
	if s.file != nil {
		(^win.IUnknown)(s.file)->Release()
	}
	if s.link != nil {
		(^win.IUnknown)(s.link)->Release()
	}
	if s.com {
		win.CoUninitialize()
	}
	s^ = {}
}

install_query :: proc(allocator := context.allocator) -> (target: string, installed: bool) {
	path := shortcut_path() or_return
	if !os.exists(path) {
		return
	}
	s := shell_link_open() or_return
	defer shell_link_close(&s)
	buf: [win.MAX_PATH * 4]u16
	if win.SUCCEEDED(s.file->Load(win.utf8_to_wstring(path, context.temp_allocator), 0)) &&
	   win.SUCCEEDED(s.link->GetPath(&buf[0], i32(len(buf)), nil, 0)) {
		target, _ = win.wstring_to_utf8(win.wstring(&buf[0]), -1, allocator)
	}
	return target, true
}

install_self :: proc(exe: string) -> (err: string) {
	path, ok := shortcut_path()
	if !ok {
		return "Could not find the Start menu."
	}
	s, sok := shell_link_open()
	if !sok {
		return "Could not make a shortcut."
	}
	defer shell_link_close(&s)
	dir, _ := os.split_path(exe)
	wexe := win.utf8_to_wstring(exe, context.temp_allocator)
	s.link->SetPath(wexe)
	s.link->SetWorkingDirectory(win.utf8_to_wstring(dir, context.temp_allocator))
	s.link->SetIconLocation(wexe, 0)
	s.link->SetDescription(win.L("Voice chat"))
	if win.FAILED(s.file->Save(win.utf8_to_wstring(path, context.temp_allocator), true)) {
		return strings.concatenate({"Could not write ", path}, context.temp_allocator)
	}
	return ""
}

uninstall_self :: proc() -> (err: string) {
	path, ok := shortcut_path()
	if !ok {
		return "Could not find the Start menu."
	}
	if os.exists(path) && os.remove(path) != nil {
		return strings.concatenate({"Could not remove ", path}, context.temp_allocator)
	}
	return ""
}
