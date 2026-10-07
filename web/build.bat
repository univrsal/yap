@echo off
rem Builds the web client into web\out (see web\build.sh, which does the work;
rem extra arguments go to the Odin build, e.g. web\build.bat -debug).
rem
rem Needs Odin, emscripten and Git for Windows (for its sh, and the curl
rem and CMake the first build fetches libopus with) on PATH. The emsdk is
rem taken from %EMSDK% if that is set, else from E:\repos\emsdk-main.
setlocal
cd /d "%~dp0\.."

if not defined EMSDK set "EMSDK=E:\repos\emsdk-main"
if not exist "%EMSDK%\emsdk_env.bat" (
	echo Could not find the emsdk in %EMSDK%; set EMSDK to its folder.
	exit /b 1
)
call "%EMSDK%\emsdk_env.bat" >nul || exit /b 1

set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not exist "%BASH%" (
	echo Could not find Git for Windows' bash in %BASH%.
	exit /b 1
)

"%BASH%" web/build.sh %*
exit /b %errorlevel%
