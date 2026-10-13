/*
Loading a system library at run time: X11's, PipeWire's and GLib's are
there on most desktops but not all, and a library linked against one
that's missing wouldn't load at all, taking watching down with sharing.
So they're opened with dlopen, and their functions are looked up into a
table of pointers typed from the library's own header:

	#define XCB_FUNCS(X) X(xcb_connect) X(xcb_disconnect)
	struct Xcb { XCB_FUNCS(YV_DL_POINTER) };
	...
	Dl_Lib lib;
	lib.open({"libxcb.so.1"}) && XCB_FUNCS(YV_DL_LOAD) true

Nothing may call these functions directly, or the library would need
them to load after all (check with `nm -D --undefined-only`).
*/
#pragma once

#include <dlfcn.h>

#include <initializer_list>

namespace yv {

struct Dl_Lib {
	void *handle = nullptr;

	// open opens the first of `names` that's there.
	bool open(std::initializer_list<const char *> names) {
		for (const char *name : names) {
			handle = dlopen(name, RTLD_NOW | RTLD_LOCAL);
			if (handle) {
				return true;
			}
		}
		return false;
	}

	template <typename T> bool sym(T &out, const char *name) {
		out = reinterpret_cast<T>(dlsym(handle, name));
		return out != nullptr;
	}
};

} // namespace yv

#define YV_DL_POINTER(f) decltype(&::f) f = nullptr;
// For use as `lib.open(...) && FUNCS(YV_DL_LOAD) true`, with the table
// and the library named `api` and `lib`.
#define YV_DL_LOAD(f) lib.sym(api.f, #f) &&
