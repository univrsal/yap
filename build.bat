@echo off
rem Builds bin\yap-server.exe and bin\yap.exe, both with the yap icon.
rem Extra arguments are passed to both builds. Run from a Visual Studio developer prompt (Odin
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

odin build src\server -vet -strict-style -out:bin\yap-server.exe "-extra-linker-flags:%ICON%.res" %DEFINES% %* || exit /b 1
odin build src\client -vet -strict-style -out:bin\yap.exe "-extra-linker-flags:%ICON%.res" %DEFINES% %* || exit /b 1
exit /b 0

:add_version
if "%YAP_VERSION:~0,1%"=="v" set "YAP_VERSION=%YAP_VERSION:~1%"
set DEFINES=%DEFINES% "-define:YAP_VERSION=\"%YAP_VERSION%\""
exit /b 0

:add_commit
rem call, in case git is a .bat/.cmd shim, which would otherwise not return.
call git diff --quiet HEAD 2>nul || set "COMMIT=%COMMIT%-dirty"
set DEFINES=%DEFINES% "-define:YAP_COMMIT=\"%COMMIT%\""
exit /b 0
