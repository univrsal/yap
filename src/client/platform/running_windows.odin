package platform

import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"
foreign import advapi32 "system:Advapi32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	CreateMutexW :: proc(lpMutexAttributes: ^win.SECURITY_ATTRIBUTES, bInitialOwner: win.BOOL, lpName: win.LPCWSTR) -> win.HANDLE ---
}

@(default_calling_convention = "system")
foreign advapi32 {
	InitializeSecurityDescriptor :: proc(pSecurityDescriptor: rawptr, dwRevision: win.DWORD) -> win.BOOL ---
	SetSecurityDescriptorDacl :: proc(pSecurityDescriptor: rawptr, bDaclPresent: win.BOOL, pDacl: rawptr, bDaclDefaulted: win.BOOL) -> win.BOOL ---
}

// mark_running creates the mutexes the installer looks for (AppMutex in
// scripts/package/yap.iss), so installing over or uninstalling a running
// yap asks to close it first instead of failing on a locked yap.exe. The
// Global\ one is seen from other sessions too, which matters when yap is
// installed for everyone; it has no DACL so other users' setup can open it.
// The handles stay open until the process exits, which releases them.
mark_running :: proc() {
	// A SECURITY_DESCRIPTOR is 40 bytes on x64 and must be pointer aligned.
	@(static) sd: [8]uintptr
	sa := win.SECURITY_ATTRIBUTES {
		nLength = size_of(win.SECURITY_ATTRIBUTES),
	}
	if InitializeSecurityDescriptor(&sd, 1) && SetSecurityDescriptorDacl(&sd, true, nil, false) {
		sa.lpSecurityDescriptor = &sd
	}
	CreateMutexW(&sa, false, win.L("YapClientRunning"))
	CreateMutexW(&sa, false, win.L("Global\\YapClientRunning"))
}
