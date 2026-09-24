@echo off
rem Builds bin\yap-server.exe and bin\yap.exe. Extra arguments are
rem passed to both builds. Run from a Visual Studio developer prompt (Odin
rem needs MSVC's linker anyway); cl.exe compiles the trimmed-down miniaudio
rem (src\client\miniaudio), RNNoise (src\client\rnn) and traycon
rem (src\client\tray), whose third-party sources are in deps\thirdparty,
rem with the static C runtime
rem (/MT) like Odin's vendor libraries, so no runtime DLL is needed.
setlocal
cd /d "%~dp0"
if not exist bin mkdir bin

set MA=src\client\miniaudio
cl /nologo /MT /O1 /c %MA%\yap_audio.c /Fo:%MA%\yap_audio.obj || exit /b 1
lib /nologo /out:%MA%\yap_audio.lib %MA%\yap_audio.obj || exit /b 1
del %MA%\yap_audio.obj

set RNN=src\client\rnn
cl /nologo /MT /O1 /c %RNN%\yap_rnn.c /Fo:%RNN%\yap_rnn.obj || exit /b 1
lib /nologo /out:%RNN%\yap_rnn.lib %RNN%\yap_rnn.obj || exit /b 1
del %RNN%\yap_rnn.obj

set TRAY=src\client\tray
cl /nologo /MT /O1 /c %TRAY%\yap_tray.c /Fo:%TRAY%\yap_tray.obj || exit /b 1
lib /nologo /out:%TRAY%\yap_tray.lib %TRAY%\yap_tray.obj || exit /b 1
del %TRAY%\yap_tray.obj

rem The version and commit (src\common\version.odin), as
rem scripts/version-defines.sh finds them. The values are passed with
rem their quotes (\" survives the command line as "), see version.odin.
set DEFINES=
if not defined YAP_VERSION (
	for /f %%i in ('git describe --tags --exact-match 2^>nul') do set YAP_VERSION=%%i
)
if defined YAP_VERSION (
	if "%YAP_VERSION:~0,1%"=="v" set YAP_VERSION=%YAP_VERSION:~1%
)
if defined YAP_VERSION set DEFINES="-define:YAP_VERSION=\"%YAP_VERSION%\""
set COMMIT=
for /f %%i in ('git rev-parse --short^=7 HEAD 2^>nul') do set COMMIT=%%i
if defined COMMIT (
	git diff --quiet HEAD 2>nul || set COMMIT=%COMMIT%-dirty
)
if defined COMMIT set DEFINES=%DEFINES% "-define:YAP_COMMIT=\"%COMMIT%\""

odin build src\server -vet -strict-style -out:bin\yap-server.exe %DEFINES% %* || exit /b 1
odin build src\client -vet -strict-style -out:bin\yap.exe %DEFINES% %* || exit /b 1
