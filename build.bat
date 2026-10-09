@echo off
rem Builds bin\yap-server.exe and bin\yap.exe, both with the yap icon. The server
rem links SQLite (src\server\sqlite), whose source is fetched into .cache the first time.
rem Extra arguments are passed to both builds. Run from a Visual Studio developer prompt (Odin
rem needs MSVC's linker anyway); cl.exe compiles the trimmed-down miniaudio
rem (src\client\audio\miniaudio), RNNoise (src\client\audio\rnn), traycon
rem (src\client\tray), tinydialogs (src\client\dialogs) and tinyaac (src\client\audio\aac), whose
rem third-party sources are in deps\thirdparty,
rem with the static C runtime
rem (/MT) like Odin's vendor libraries, so no runtime DLL is needed.
rem libopus (src\client\audio\opus) is fetched into .cache and built with
rem CMake, which comes with Visual Studio's C++ CMake tools.
setlocal
cd /d "%~dp0"
if not exist bin mkdir bin

rem Always compile the C archives for the x64 Odin target. This also makes
rem build.bat work from an ordinary command prompt, like the CI setup does.
set "VCVARSALL="
for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find VC\Auxiliary\Build\vcvarsall.bat`) do set "VCVARSALL=%%i"
if not defined VCVARSALL (
	echo Could not find Visual Studio's x64 C++ build tools.
	exit /b 1
)
call "%VCVARSALL%" x64 >nul || exit /b 1

set MA=src\client\audio\miniaudio
cl /nologo /MT /O1 /c %MA%\yap_audio.c /Fo:%MA%\yap_audio.obj || exit /b 1
lib /nologo /out:%MA%\yap_audio.lib %MA%\yap_audio.obj || exit /b 1
del %MA%\yap_audio.obj

set RNN=src\client\audio\rnn
cl /nologo /MT /O1 /c %RNN%\yap_rnn.c /Fo:%RNN%\yap_rnn.obj || exit /b 1
lib /nologo /out:%RNN%\yap_rnn.lib %RNN%\yap_rnn.obj || exit /b 1
del %RNN%\yap_rnn.obj

set TRAY=src\client\tray
cl /nologo /MT /O1 /c %TRAY%\yap_tray.c /Fo:%TRAY%\yap_tray.obj || exit /b 1
lib /nologo /out:%TRAY%\yap_tray.lib %TRAY%\yap_tray.obj || exit /b 1
del %TRAY%\yap_tray.obj

set DIALOGS=src\client\dialogs
cl /nologo /MT /O1 /c %DIALOGS%\yap_dialogs.c /Fo:%DIALOGS%\yap_dialogs.obj || exit /b 1
lib /nologo /out:%DIALOGS%\yap_dialogs.lib %DIALOGS%\yap_dialogs.obj || exit /b 1
del %DIALOGS%\yap_dialogs.obj

set AAC=src\client\audio\aac
cl /nologo /MT /O1 /c %AAC%\yap_aac.c /Fo:%AAC%\yap_aac.obj || exit /b 1
lib /nologo /out:%AAC%\yap_aac.lib %AAC%\yap_aac.obj || exit /b 1
del %AAC%\yap_aac.obj

rem libopus, for the voice codec (src\client\audio\opus): fetched into
rem .cache on first use and built from the release source with the static
rem C runtime, the float API without DRED or OSCE, which is what
rem src\client\audio\opus binds. Delete opus.lib after changing
rem scripts\opus.version to build it again.
set OPUS=src\client\audio\opus
if not exist %OPUS%\opus.lib call :build_opus || exit /b 1

rem SQLite, for the server's database (src\server\sqlite): one big C file,
rem fetched into .cache on first use and compiled the way yap_sqlite.c
rem configures it. It takes a little while, so it's only built when the
rem library isn't there; delete it after changing yap_sqlite.c or
rem scripts\sqlite.version. curl and tar come with Windows 10 and later.
set SQLITE=src\server\sqlite
if not exist %SQLITE%\yap_sqlite.lib call :build_sqlite || exit /b 1

rem The version and commit (src\common\version.odin), as
rem scripts/version-defines.sh finds them. The values are passed with
rem their quotes (\" survives the command line as "), see version.odin.
rem No ( ) blocks here: cmd expands a whole block before running any of
rem it, and %VAR:~0,1% of a variable that isn't set comes out as stray
rem text that can unbalance the quotes and break the block (CI sets
rem YAP_VERSION to nothing). The subroutines only run once it's set.
set DEFINES=
if "%YAP_VERSION%"=="" for /f "delims=" %%i in ('git describe --tags --exact-match 2^>nul') do set "YAP_VERSION=%%i"
if not "%YAP_VERSION%"=="" call :add_version
set COMMIT=
for /f "delims=" %%i in ('git rev-parse --short^=7 HEAD 2^>nul') do set "COMMIT=%%i"
if not "%COMMIT%"=="" call :add_commit

rem The programs' icon (src\client\assets\icon.rc), which Explorer shows:
rem rc.exe compiles it, and MSVC's linker takes the .res as it is.
set ICON=src\client\assets\icon
rc /nologo /i src\client\assets /fo %ICON%.res %ICON%.rc || exit /b 1

rem The collections the imports name: "common:wlog", "client:audio/opus".
set COLLECTIONS=-collection:common=src\common -collection:client=src\client
odin build src\server %COLLECTIONS% -vet -strict-style -out:bin\yap-server.exe "-extra-linker-flags:%ICON%.res" %DEFINES% %* || exit /b 1
odin build src\client %COLLECTIONS% -vet -strict-style -out:bin\yap.exe "-extra-linker-flags:%ICON%.res /SUBSYSTEM:WINDOWS" %DEFINES% %* || exit /b 1
exit /b 0

:build_sqlite
rem scripts\sqlite.version is name=value lines, and # comments.
for /f "usebackq eol=# tokens=1,2 delims==" %%a in ("scripts\sqlite.version") do set "%%a=%%b"
set SQLITE_NAME=sqlite-autoconf-%sqlite_version%
if not exist .cache mkdir .cache
if exist .cache\%SQLITE_NAME%\sqlite3.c goto :compile_sqlite
if not exist .cache\%SQLITE_NAME%.tar.gz (
	echo fetching sqlite %sqlite_version%
	curl -fL --retry 3 -o .cache\%SQLITE_NAME%.tar.gz.part https://www.sqlite.org/%sqlite_year%/%SQLITE_NAME%.tar.gz || exit /b 1
	move /y .cache\%SQLITE_NAME%.tar.gz.part .cache\%SQLITE_NAME%.tar.gz >nul || exit /b 1
)
rem certutil prints the sum on a line of its own, in lower case.
certutil -hashfile .cache\%SQLITE_NAME%.tar.gz SHA256 | findstr /x /i /c:"%sqlite_sha256%" >nul
if errorlevel 1 (
	echo .cache\%SQLITE_NAME%.tar.gz: checksum mismatch; delete it to fetch it again
	exit /b 1
)
tar -xzf .cache\%SQLITE_NAME%.tar.gz -C .cache || exit /b 1
:compile_sqlite
echo building %SQLITE%\yap_sqlite.lib
cl /nologo /MT /O1 /I.cache\%SQLITE_NAME% /c %SQLITE%\yap_sqlite.c /Fo:%SQLITE%\yap_sqlite.obj || exit /b 1
lib /nologo /out:%SQLITE%\yap_sqlite.lib %SQLITE%\yap_sqlite.obj || exit /b 1
del %SQLITE%\yap_sqlite.obj
exit /b 0

:build_opus
rem scripts\opus.version is name=value lines, and # comments.
for /f "usebackq eol=# tokens=1,2 delims==" %%a in ("scripts\opus.version") do set "%%a=%%b"
set OPUS_NAME=opus-%opus_version%
if not exist .cache mkdir .cache
if exist .cache\%OPUS_NAME%\CMakeLists.txt goto :compile_opus
if not exist .cache\%OPUS_NAME%.tar.gz (
	echo fetching opus %opus_version%
	curl -fL --retry 3 -o .cache\%OPUS_NAME%.tar.gz.part https://downloads.xiph.org/releases/opus/%OPUS_NAME%.tar.gz || exit /b 1
	move /y .cache\%OPUS_NAME%.tar.gz.part .cache\%OPUS_NAME%.tar.gz >nul || exit /b 1
)
certutil -hashfile .cache\%OPUS_NAME%.tar.gz SHA256 | findstr /x /i /c:"%opus_sha256%" >nul
if errorlevel 1 (
	echo .cache\%OPUS_NAME%.tar.gz: checksum mismatch; delete it to fetch it again
	exit /b 1
)
tar -xzf .cache\%OPUS_NAME%.tar.gz -C .cache || exit /b 1
:compile_opus
echo building %OPUS%\opus.lib
where cmake >nul 2>nul || goto :no_cmake
rem Ninja if it's there (it comes with CMake in Visual Studio), as NMake
rem builds one file at a time.
set "OPUS_GEN=NMake Makefiles"
where ninja >nul 2>nul && set OPUS_GEN=Ninja
if exist .cache\%OPUS_NAME%-windows rmdir /s /q .cache\%OPUS_NAME%-windows
cmake -S .cache\%OPUS_NAME% -B .cache\%OPUS_NAME%-windows -G "%OPUS_GEN%" ^
	-DCMAKE_BUILD_TYPE=Release ^
	-DCMAKE_C_COMPILER=cl ^
	-DOPUS_STATIC_RUNTIME=ON ^
	-DOPUS_BUILD_PROGRAMS=OFF ^
	-DOPUS_BUILD_TESTING=OFF ^
	-DOPUS_INSTALL_PKG_CONFIG_MODULE=OFF ^
	-DOPUS_INSTALL_CMAKE_CONFIG_MODULE=OFF >nul || exit /b 1
cmake --build .cache\%OPUS_NAME%-windows --parallel || exit /b 1
copy /y .cache\%OPUS_NAME%-windows\opus.lib %OPUS%\opus.lib >nul || exit /b 1
exit /b 0

:no_cmake
echo CMake is needed to build libopus: install Visual Studio's "C++ CMake tools for Windows"
exit /b 1

:add_version
if "%YAP_VERSION:~0,1%"=="v" set "YAP_VERSION=%YAP_VERSION:~1%"
set DEFINES=%DEFINES% "-define:YAP_VERSION=%YAP_VERSION%"
exit /b 0

:add_commit
rem call, in case git is a .bat/.cmd shim, which would otherwise not return.
call git diff --quiet HEAD 2>nul || set "COMMIT=%COMMIT%-dirty"
set DEFINES=%DEFINES% "-define:YAP_COMMIT=\"%COMMIT%\""
exit /b 0
