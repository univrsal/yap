@echo off
rem Builds the optional screen sharing library, yap_video.dll
rem (src\video, misc\hq-share\README.md), dshowcapture.dll for its cameras
rem (misc\video-chat\README.md), and yv-loopback.exe into bin\
rem next to the client, with the FFmpeg DLLs it needs beside them. The
rem client runs without any of it; build.bat never builds it.
rem FFmpeg is BtbN's LGPL shared build (scripts\ffmpeg.version), fetched
rem into .cache the first time. Needs Visual Studio's C++ tools and
rem CMake. Extra arguments go to CMake's configure step.
setlocal
cd /d "%~dp0.."
if not exist bin mkdir bin

set "VCVARSALL="
for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find VC\Auxiliary\Build\vcvarsall.bat`) do set "VCVARSALL=%%i"
if not defined VCVARSALL (
	echo Could not find Visual Studio's x64 C++ build tools.
	exit /b 1
)
call "%VCVARSALL%" x64 >nul || exit /b 1
where cmake >nul 2>nul || (
	echo CMake is needed: install Visual Studio's "C++ CMake tools for Windows"
	exit /b 1
)

call :fetch_ffmpeg || exit /b 1

set "GEN=NMake Makefiles"
where ninja >nul 2>nul && set GEN=Ninja
set BUILD=.cache\video-build
cmake -S src\video -B %BUILD% -G "%GEN%" -DCMAKE_BUILD_TYPE=Release ^
	-DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl ^
	"-DFFMPEG_DIR=%CD%\.cache\%ffmpeg_win%" %* || exit /b 1
cmake --build %BUILD% --parallel || exit /b 1
cmake --install %BUILD% --prefix bin >nul || exit /b 1
rem Only the DLLs yap_video links, and what they link.
for %%l in (avcodec avutil swresample swscale) do (
	copy /y .cache\%ffmpeg_win%\bin\%%l-*.dll bin\ >nul || exit /b 1
)
rem And the licence that has to go with them.
copy /y .cache\%ffmpeg_win%\LICENSE.txt bin\ffmpeg-LICENSE.txt >nul || exit /b 1
rem dshowcapture.dll (cameras) is libdshowcapture, LGPL too.
copy /y src\video\thirdparty\dshowcapture\COPYING bin\dshowcapture-LICENSE.txt >nul || exit /b 1
echo built bin\yap_video.dll, bin\dshowcapture.dll and bin\yv-loopback.exe; try: bin\yv-loopback --list
exit /b 0

:fetch_ffmpeg
rem scripts\ffmpeg.version is name=value lines, and # comments.
for /f "usebackq eol=# tokens=1,2 delims==" %%a in ("scripts\ffmpeg.version") do set "%%a=%%b"
if not exist .cache mkdir .cache
if exist .cache\%ffmpeg_win%\include exit /b 0
if not exist .cache\%ffmpeg_win%.zip (
	echo fetching %ffmpeg_win%
	curl -fL --retry 5 --retry-all-errors --retry-delay 5 --connect-timeout 30 --speed-limit 1024 --speed-time 60 -o .cache\%ffmpeg_win%.zip.part https://github.com/BtbN/FFmpeg-Builds/releases/download/%ffmpeg_release%/%ffmpeg_win%.zip || exit /b 1
	move /y .cache\%ffmpeg_win%.zip.part .cache\%ffmpeg_win%.zip >nul || exit /b 1
)
certutil -hashfile .cache\%ffmpeg_win%.zip SHA256 | findstr /x /i /c:"%ffmpeg_win_sha256%" >nul
if errorlevel 1 (
	echo .cache\%ffmpeg_win%.zip: checksum mismatch; delete it to fetch it again
	exit /b 1
)
rem Windows' tar is bsdtar, which unpacks zips too.
tar -xf .cache\%ffmpeg_win%.zip -C .cache || exit /b 1
exit /b 0
