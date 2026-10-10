#!/bin/sh
# libwebp, for WebP pictures (src/common/webp, which the client and the
# server both use): built from the release source (scripts/fetch-webp.sh,
# scripts/webp.version) for size, but with its SIMD code, which decodes
# and compresses twice as fast for ~80 KB. Without threads, which yap
# doesn't ask it for, so it needs no pthread. Only built when it isn't
# there, as the CI keeps it between runs; delete src/common/webp/libwebp.a
# after changing scripts/webp.version. yap_webp.c, the part
# src/common/webp binds, is compiled when it has changed.
# build.sh and the Dockerfile run this from the top of the repo;
# build.bat does the same on Windows.
set -e
webp=src/common/webp
if [ ! -f "$webp/libwebp.a" ] || [ ! -f "$webp/libwebpdemux.a" ] || [ ! -f "$webp/libsharpyuv.a" ]; then
	scripts/fetch-webp.sh .cache
	. scripts/webp.version
	echo "building $webp/libwebp.a"
	cmake -S ".cache/libwebp-$webp_version" -B ".cache/libwebp-$webp_version-build" \
		-DCMAKE_BUILD_TYPE=MinSizeRel \
		-DBUILD_SHARED_LIBS=OFF \
		-DWEBP_USE_THREAD=OFF \
		-DWEBP_BUILD_ANIM_UTILS=OFF \
		-DWEBP_BUILD_CWEBP=OFF \
		-DWEBP_BUILD_DWEBP=OFF \
		-DWEBP_BUILD_GIF2WEBP=OFF \
		-DWEBP_BUILD_IMG2WEBP=OFF \
		-DWEBP_BUILD_VWEBP=OFF \
		-DWEBP_BUILD_WEBPINFO=OFF \
		-DWEBP_BUILD_LIBWEBPMUX=OFF \
		-DWEBP_BUILD_WEBPMUX=OFF \
		-DWEBP_BUILD_EXTRAS=OFF >/dev/null
	# A job count, since OpenBSD's make won't take a bare -j.
	jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || getconf NPROCESSORS_ONLN)
	cmake --build ".cache/libwebp-$webp_version-build" --parallel "$jobs"
	cp ".cache/libwebp-$webp_version-build/libwebp.a" ".cache/libwebp-$webp_version-build/libwebpdemux.a" \
		".cache/libwebp-$webp_version-build/libsharpyuv.a" "$webp/"
fi
lib=$webp/libyap_webp.a
if [ ! -f "$lib" ] || [ "$webp/yap_webp.c" -nt "$lib" ]; then
	# The headers, which the CI's kept libraries come without.
	scripts/fetch-webp.sh .cache
	. scripts/webp.version
	echo "building $lib"
	${CC:-cc} -std=c99 -Os -I".cache/libwebp-$webp_version/src" -c "$webp/yap_webp.c" -o "$webp/yap_webp.o"
	ar rcs "$lib" "$webp/yap_webp.o"
	rm "$webp/yap_webp.o"
fi
