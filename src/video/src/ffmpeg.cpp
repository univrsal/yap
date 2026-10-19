// Opening FFmpeg at run time (ffmpeg.h).
#define YV_FFMPEG_TABLE_ONLY
#include "ffmpeg.h"

#include "internal.h"

#include <string>

#if !defined(_WIN32)
#include <dlfcn.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif
#endif

namespace yv {

#if defined(_WIN32)

// Linked, from next to the library.
bool load_ffmpeg() {
	return true;
}

const char *ffmpeg_where() {
	return "next to yap_video";
}

bool ffmpeg_bundled() {
	return true;
}

#else

Ffmpeg ff;

namespace {

/*
An FFmpeg version we take, by its libraries' names, in the order
they're opened: libavutil first, so the others find it already open
rather than looking for it themselves. libswresample isn't ours, but
libavcodec may need it (BtbN's does), and the ones we ship have no run
path to find each other by. The best fit for the headers comes first.
*/
struct Version {
	unsigned avcodec, avutil, swscale; // their major versions
	const char *avutil_name, *swresample_name, *avcodec_name, *swscale_name;
};

#if defined(__APPLE__)
const Version versions[] = {
	{62, 60, 9, "libavutil.60.dylib", "libswresample.6.dylib", "libavcodec.62.dylib",
	 "libswscale.9.dylib"},
	{63, 61, 10, "libavutil.61.dylib", "libswresample.7.dylib", "libavcodec.63.dylib",
	 "libswscale.10.dylib"},
};
// Where else to look, after dlopen's own search ("" ): Homebrew's on
// Apple silicon and on Intel, and MacPorts'.
const char *const system_dirs[] = {"", "/opt/homebrew/lib/", "/usr/local/lib/", "/opt/local/lib/"};
#else
const Version versions[] = {
	{62, 60, 9, "libavutil.so.60", "libswresample.so.6", "libavcodec.so.62", "libswscale.so.9"},
	{63, 61, 10, "libavutil.so.61", "libswresample.so.7", "libavcodec.so.63", "libswscale.so.10"},
};
const char *const system_dirs[] = {""};
#endif

std::string where;
bool bundled = false;

// own_dir is the folder this library is in, with a slash at the end,
// or the program's when it's linked into the program; "" if unknown.
std::string own_dir() {
	std::string path;
	Dl_info info{};
	if (dladdr(reinterpret_cast<void *>(&load_ffmpeg), &info) && info.dli_fname &&
	    info.dli_fname[0] == '/') {
		path = info.dli_fname;
	} else {
		char buf[4096];
#if defined(__APPLE__)
		uint32_t size = sizeof(buf);
		if (_NSGetExecutablePath(buf, &size) == 0) {
			path = buf;
		}
#else
		ssize_t n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
		if (n > 0) {
			path.assign(buf, static_cast<size_t>(n));
		}
#endif
	}
	size_t slash = path.rfind('/');
	return slash == std::string::npos ? "" : path.substr(0, slash + 1);
}

struct Libs {
	void *avutil = nullptr, *swresample = nullptr, *avcodec = nullptr, *swscale = nullptr;

	void close() {
		for (void *h : {swscale, avcodec, swresample, avutil}) {
			if (h) {
				dlclose(h);
			}
		}
		*this = {};
	}
};

void *open_lib(const std::string &path, std::string &why) {
	void *h = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
	if (!h) {
		const char *e = dlerror();
		why = e ? e : path + ": can't open";
	}
	return h;
}

// Each function is in libavcodec or libswscale, or in libavutil, which
// both of them lead to.
template <typename T> bool find(T &out, const char *name, const Libs &l) {
	void *p = dlsym(l.avcodec, name);
	if (!p) {
		p = dlsym(l.swscale, name);
	}
	out = reinterpret_cast<T>(p);
	return p != nullptr;
}

#define YV_FFMPEG_FIND(f) find(api.f, #f, l) &&

// open_version opens FFmpeg version `v` in `dir` ("" for wherever
// dlopen finds it) into ff, or says why it couldn't.
bool open_version(const std::string &dir, const Version &v, std::string &why) {
	Libs l;
	l.avutil = open_lib(dir + v.avutil_name, why);
	if (!l.avutil) {
		return false;
	}
	if (!dir.empty()) {
		// Only if it's there: a build may not need it.
		l.swresample = dlopen((dir + v.swresample_name).c_str(), RTLD_NOW | RTLD_LOCAL);
	}
	l.avcodec = open_lib(dir + v.avcodec_name, why);
	l.swscale = l.avcodec ? open_lib(dir + v.swscale_name, why) : nullptr;
	if (!l.swscale) {
		l.close();
		return false;
	}
	Ffmpeg api;
	if (!(YV_FFMPEG_FUNCS(YV_FFMPEG_FIND) true)) {
		why = dir + v.avcodec_name + ": missing a function we use";
		l.close();
		return false;
	}
	if (api.avcodec_version() >> 16 != v.avcodec || api.avutil_version() >> 16 != v.avutil ||
	    api.swscale_version() >> 16 != v.swscale) {
		why = dir + v.avcodec_name + ": its libraries are of other versions";
		l.close();
		return false;
	}
	ff = api;
	Dl_info info{};
	if (dladdr(reinterpret_cast<void *>(api.avcodec_version), &info) && info.dli_fname) {
		where = info.dli_fname;
	} else {
		where = dir + v.avcodec_name;
	}
	// The handles stay open for good.
	return true;
}

#undef YV_FFMPEG_FIND

bool open_any() {
	std::string own = own_dir();
	std::string why;
	if (!own.empty()) {
		for (const Version &v : versions) {
			if (open_version(own, v, why)) {
				bundled = true;
				return true;
			}
			log(YV_LOG_DEBUG, "FFmpeg: %s", why.c_str());
		}
	}
	for (const char *dir : system_dirs) {
		for (const Version &v : versions) {
			if (open_version(dir, v, why)) {
				return true;
			}
			log(YV_LOG_DEBUG, "FFmpeg: %s", why.c_str());
		}
	}
	log(YV_LOG_WARN,
	    "no FFmpeg 8 or 9 next to yap_video or on the system (%s or %s), "
	    "so no screen sharing",
	    versions[0].avcodec_name, versions[1].avcodec_name);
	return false;
}

} // namespace

bool load_ffmpeg() {
	static const bool loaded = open_any();
	return loaded;
}

const char *ffmpeg_where() {
	return where.c_str();
}

bool ffmpeg_bundled() {
	return bundled;
}

#endif

} // namespace yv
