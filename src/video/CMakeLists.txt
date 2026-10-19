# yap_video, the optional screen sharing library (misc/hq-share/README.md).
# Built by scripts/build-video.sh / build-video.bat, never by build.sh or
# build.bat: the client runs without it.
#
# FFMPEG_DIR is an FFmpeg with include/ and lib/ (and bin/ on Windows,
# for the DLLs), as the build scripts fetch it. Without it, pkg-config
# looks for the system's.
cmake_minimum_required(VERSION 3.21)
# ScreenCaptureKit's first (D10 in the plan); ignored elsewhere.
set(CMAKE_OSX_DEPLOYMENT_TARGET "12.3" CACHE STRING "oldest macOS")
project(yap_video LANGUAGES C CXX)
if(APPLE)
	enable_language(OBJCXX)
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)
# The static C runtime, like the rest of yap on Windows, so there's no
# runtime DLL to ship. FFmpeg's DLLs bring their own (the UCRT).
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

set(FFMPEG_DIR "" CACHE PATH "FFmpeg with include/ and lib/")
add_library(ffmpeg INTERFACE)
if(FFMPEG_DIR)
	target_include_directories(ffmpeg SYSTEM INTERFACE "${FFMPEG_DIR}/include")
	if(WIN32)
		target_link_libraries(ffmpeg INTERFACE
			"${FFMPEG_DIR}/lib/avcodec.lib" "${FFMPEG_DIR}/lib/avutil.lib"
			"${FFMPEG_DIR}/lib/swscale.lib")
	else()
		# By full path, so CMake knows where they are and programs in the
		# build folder find them when run. Installing sets the run path to
		# $ORIGIN instead.
		target_link_libraries(ffmpeg INTERFACE
			"${FFMPEG_DIR}/lib/libavcodec${CMAKE_SHARED_LIBRARY_SUFFIX}"
			"${FFMPEG_DIR}/lib/libavutil${CMAKE_SHARED_LIBRARY_SUFFIX}"
			"${FFMPEG_DIR}/lib/libswscale${CMAKE_SHARED_LIBRARY_SUFFIX}")
	endif()
else()
	find_package(PkgConfig REQUIRED)
	pkg_check_modules(LIBAV REQUIRED IMPORTED_TARGET libavcodec libavutil libswscale)
	target_link_libraries(ffmpeg INTERFACE PkgConfig::LIBAV)
endif()

set(SOURCES src/context.cpp src/encoders.cpp src/view.cpp src/yuv.cpp src/share.cpp src/camera.cpp)
set(CAPTURE_INCLUDES "")
set(CAPTURE_DEFINES "")
if(WIN32)
	list(APPEND SOURCES src/sources_win.cpp src/output_d3d11.cpp src/capture_win.cpp src/camera_win.cpp)
elseif(APPLE)
	# ScreenCaptureKit, Metal and AVFoundation (cameras) are Objective-C, so these are Objective-C++.
	list(APPEND SOURCES src/output_metal.mm src/sources_mac.mm src/capture_mac.mm src/camera_mac.mm src/camera_fake.cpp)
	set_source_files_properties(src/output_metal.mm src/sources_mac.mm src/capture_mac.mm src/camera_mac.mm
		PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
else()
	# X11 (XCB) and the portal (GLib's GIO, PipeWire). Only their headers
	# are needed to build: the libraries are loaded at run time
	# (src/dl_linux.h), so the library loads without them. A way of
	# capturing whose headers are missing is left out.
	list(APPEND SOURCES src/output_gl.cpp src/gl_interop_linux.cpp src/capture_linux.cpp src/camera_v4l2.cpp src/camera_fake.cpp)
	find_package(PkgConfig REQUIRED)
	pkg_check_modules(XCB IMPORTED_TARGET xcb xcb-shm xcb-randr xcb-composite xcb-xfixes)
	pkg_check_modules(PORTAL IMPORTED_TARGET gio-unix-2.0 libpipewire-0.3)
	if(XCB_FOUND)
		list(APPEND SOURCES src/x11_linux.cpp)
		list(APPEND CAPTURE_INCLUDES ${XCB_INCLUDE_DIRS})
	else()
		message(WARNING "no XCB headers (libxcb*-dev): no X11 capture")
		list(APPEND CAPTURE_DEFINES YV_NO_X11)
	endif()
	if(PORTAL_FOUND)
		list(APPEND SOURCES src/portal_linux.cpp)
		list(APPEND CAPTURE_INCLUDES ${PORTAL_INCLUDE_DIRS})
		# The portal's DMA-BUFs into VA-API need libva's headers too
		# (libva-dev); without them it's shared memory only.
		pkg_check_modules(LIBVA libva)
		if(LIBVA_FOUND)
			list(APPEND SOURCES src/vpp_linux.cpp)
			list(APPEND CAPTURE_INCLUDES ${LIBVA_INCLUDE_DIRS})
		else()
			message(WARNING "no libva headers (libva-dev): the portal's pictures go through memory")
			list(APPEND CAPTURE_DEFINES YV_NO_DMABUF)
		endif()
	else()
		message(WARNING "no GIO or PipeWire headers (libglib2.0-dev, libpipewire-0.3-dev): no portal capture")
		list(APPEND CAPTURE_DEFINES YV_NO_PORTAL)
	endif()
endif()

add_library(yap_video SHARED ${SOURCES})
target_include_directories(yap_video PUBLIC include)
target_compile_definitions(yap_video PRIVATE YV_BUILDING ${CAPTURE_DEFINES})
target_include_directories(yap_video SYSTEM PRIVATE ${CAPTURE_INCLUDES})
target_link_libraries(yap_video PRIVATE ffmpeg)
if(WIN32)
	target_compile_definitions(yap_video PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX UNICODE _UNICODE _CRT_SECURE_NO_WARNINGS)
	# windowsapp: WinRT, for Windows.Graphics.Capture (C++/WinRT, from the SDK).
	# ole32 and advapi32: COM and the registry, for cameras.
	target_link_libraries(yap_video PRIVATE dwmapi user32 d3d11 dxgi d3dcompiler windowsapp ole32 advapi32)

	# Cameras: libdshowcapture (LGPL) as a DLL of its own, dshowcapture.dll,
	# with yv_dshow.cpp as its C face. yap_video loads it at run time
	# (src/camera_win.cpp), so it isn't linked here.
	set(DSHOW thirdparty/dshowcapture)
	file(GLOB DSHOW_SOURCES ${DSHOW}/source/*.cpp)
	add_library(dshowcapture SHARED ${DSHOW_SOURCES} ${DSHOW}/yv_dshow.cpp)
	target_include_directories(dshowcapture PRIVATE ${DSHOW})
	# Upstream's standard.
	set_target_properties(dshowcapture PROPERTIES CXX_STANDARD 17)
	target_compile_definitions(dshowcapture PRIVATE UNICODE _UNICODE _UP_WINDOWS=1 NOMINMAX)
	target_link_libraries(dshowcapture PRIVATE setupapi strmiids ksuser winmm wmcodecdspuuid ole32 oleaut32 uuid)
	if(MSVC)
		# As upstream builds it.
		target_compile_options(dshowcapture PRIVATE /W4 /wd4127 /wd4201 /utf-8)
	endif()
	install(TARGETS dshowcapture RUNTIME DESTINATION .)
endif()
if(MSVC)
	target_compile_options(yap_video PRIVATE /W4 /utf-8 /bigobj)
else()
	target_compile_options(yap_video PRIVATE -Wall -Wextra)
endif()
if(APPLE)
	target_link_libraries(yap_video PRIVATE "-framework ScreenCaptureKit" "-framework AVFoundation"
		"-framework CoreMedia" "-framework CoreVideo" "-framework CoreGraphics"
		"-framework Foundation" "-framework AppKit" "-framework Metal" "-framework IOSurface")
endif()
if(NOT WIN32 AND NOT APPLE)
	# dlopen, for the above; shm*, for MIT-SHM.
	target_link_libraries(yap_video PRIVATE ${CMAKE_DL_LIBS})
endif()
# Once installed, find FFmpeg's libraries (and the tool the library) in
# the same folder.
if(APPLE)
	set(HERE "@loader_path")
else()
	set(HERE "$ORIGIN")
endif()
if(NOT WIN32)
	set_target_properties(yap_video PROPERTIES INSTALL_RPATH "${HERE}")
endif()
if(NOT WIN32 AND NOT APPLE)
	# As DT_RPATH, not DT_RUNPATH: a run path only covers the object's own
	# dependencies, but an rpath covers everything loaded under it, and
	# FFmpeg's libraries (BtbN's have no run path) need each other. This
	# is what lets the client dlopen the library from next to itself.
	target_link_options(yap_video PRIVATE "-Wl,--disable-new-dtags")
endif()

add_executable(yv-loopback tools/yv_loopback.cpp tools/stream_file.cpp
	$<IF:$<BOOL:${WIN32}>,tools/play_win.cpp,tools/play_other.cpp>)
target_link_libraries(yv-loopback PRIVATE yap_video)
if(MSVC)
	target_compile_options(yv-loopback PRIVATE /W4 /utf-8)
	target_compile_definitions(yv-loopback PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX _CRT_SECURE_NO_WARNINGS)
endif()
if(APPLE)
	# An Info.plist in the executable itself, for the camera (tools/Info.plist).
	target_link_options(yv-loopback PRIVATE
		"LINKER:-sectcreate,__TEXT,__info_plist,${CMAKE_CURRENT_SOURCE_DIR}/tools/Info.plist")
	set_property(TARGET yv-loopback APPEND PROPERTY LINK_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/tools/Info.plist")
endif()
if(WIN32)
	target_link_libraries(yv-loopback PRIVATE d3d11 dxgi d3dcompiler user32)
else()
	set_target_properties(yv-loopback PROPERTIES INSTALL_RPATH "${HERE}")
endif()
if(FFMPEG_DIR AND NOT WIN32 AND NOT APPLE)
	# The linker checks that the library's FFmpeg resolves, and FFmpeg's
	# libraries need each other (libavcodec, libswresample): tell it
	# where they all are.
	target_link_options(yv-loopback PRIVATE "-Wl,-rpath-link,${FFMPEG_DIR}/lib")
endif()
if(NOT WIN32 AND NOT APPLE)
	target_link_options(yv-loopback PRIVATE "-Wl,--disable-new-dtags")
endif()

install(TARGETS yap_video yv-loopback RUNTIME DESTINATION . LIBRARY DESTINATION .)
