@echo off
rem Builds bin\yap-server.exe and bin\yap-client.exe. Extra arguments are
rem passed to both builds. Run from a Visual Studio developer prompt (Odin
rem needs MSVC's linker anyway); cl.exe compiles the trimmed-down miniaudio
rem in client\miniaudio.
setlocal
cd /d "%~dp0"
if not exist bin mkdir bin

set MA=client\miniaudio
cl /nologo /O1 /c %MA%\yap_audio.c /Fo:%MA%\yap_audio.obj || exit /b 1
lib /nologo /out:%MA%\yap_audio.lib %MA%\yap_audio.obj || exit /b 1
del %MA%\yap_audio.obj

odin build server -vet -strict-style -out:bin\yap-server.exe %* || exit /b 1
odin build client -vet -strict-style -out:bin\yap-client.exe %* || exit /b 1
