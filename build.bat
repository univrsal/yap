@echo off
rem Builds bin\yap-server.exe and bin\yap-client.exe. Extra arguments are
rem passed to both builds. Run from a Visual Studio developer prompt (Odin
rem needs MSVC's linker anyway); cl.exe compiles the trimmed-down miniaudio
rem (client\miniaudio), RNNoise (client\rnn) and traycon (client\tray),
rem with the static C runtime
rem (/MT) like Odin's vendor libraries, so no runtime DLL is needed.
setlocal
cd /d "%~dp0"
if not exist bin mkdir bin

set MA=client\miniaudio
cl /nologo /MT /O1 /c %MA%\yap_audio.c /Fo:%MA%\yap_audio.obj || exit /b 1
lib /nologo /out:%MA%\yap_audio.lib %MA%\yap_audio.obj || exit /b 1
del %MA%\yap_audio.obj

set RNN=client\rnn
cl /nologo /MT /O1 /c %RNN%\yap_rnn.c /Fo:%RNN%\yap_rnn.obj || exit /b 1
lib /nologo /out:%RNN%\yap_rnn.lib %RNN%\yap_rnn.obj || exit /b 1
del %RNN%\yap_rnn.obj

set TRAY=client\tray
cl /nologo /MT /O1 /c %TRAY%\yap_tray.c /Fo:%TRAY%\yap_tray.obj || exit /b 1
lib /nologo /out:%TRAY%\yap_tray.lib %TRAY%\yap_tray.obj || exit /b 1
del %TRAY%\yap_tray.obj

odin build server -vet -strict-style -out:bin\yap-server.exe %* || exit /b 1
odin build client -vet -strict-style -out:bin\yap-client.exe %* || exit /b 1
odin build relay -vet -strict-style -out:bin\yap-relay.exe %* || exit /b 1
