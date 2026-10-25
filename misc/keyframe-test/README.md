# Keyframe test: does the encoder answer keyframe requests?

A viewer that has lost frames, or has only just started watching, can only
decode again from a keyframe, and asks the sharer for one
(`yv_share_request_key`). If the encoder makes an ordinary I frame instead,
the packet isn't flagged as a keyframe and the viewer drops it. The picture
then stays frozen until the next keyframe the encoder makes on its own: at a
bitrate change (which starts most encoders again) or every 10 seconds
(`KEY_SECONDS` in `src/video/src/share.cpp`).

## What was found

2026-10-16, Windows, AMD RX 6700 XT, `hevc_amf`: none of four requests was
answered; only the encoder's very first frame was a keyframe. FFmpeg's AMF
encoders make IDR frames for a request only with `forced_idr` set, which is
off by default. With `forced_idr=1` (`encoder_options` in `share.cpp`) every
request was answered by the next frame, about 15 ms later. Over a VPS this
showed as seconds before a new viewer's first picture, and as long stalls
after losses.

Still to check: Linux/Wayland (VA-API, presumably `hevc_vaapi`), which showed
similar stalls. NVENC and Quick Sync get `forced-idr`/`forced_idr` already.

## Running it

`keytest.cpp` shares a monitor at 1080p60, 8000 kbit/s with the encoder you
name, asks for a keyframe once a second for 5 seconds and prints which
packets are keyframes. It ends with `OK` (exit 0) if every request was
answered, else `BROKEN` (exit 2). Without an encoder argument it lists the
encoders that work. On Wayland the portal's picker opens first; the clock
starts once the share is live.

Build the library first (`scripts/build/build-video.sh`, or `scripts\build\build-video.bat`
on Windows), then from the repository root:

Linux:

```sh
g++ -std=c++20 -O1 -I src/video/include misc/keyframe-test/keytest.cpp \
	-o .cache/keytest -L bin -lyap_video -Wl,-rpath-link,bin
LD_LIBRARY_PATH=bin .cache/keytest            # lists the encoders
LD_LIBRARY_PATH=bin .cache/keytest hevc_vaapi
```

Windows, in a Visual Studio x64 developer prompt (the program has to sit next
to `yap_video.dll` and FFmpeg's DLLs):

```bat
cl /nologo /EHsc /O1 /I src\video\include misc\keyframe-test\keytest.cpp ^
	/Fe:bin\keytest.exe /Fo:.cache\keytest.obj .cache\video-build\yap_video.lib
bin\keytest hevc_amf
```

A healthy run looks like this (each request answered by the next frame):

```
    0 ms: frame 1 is a keyframe, 141287 bytes
 1003 ms: asking for a keyframe
 1018 ms: frame 54 is a keyframe, 204052 bytes (15 ms after asking)
 ...
322 frames, 5 of 5 keyframe requests answered: OK
```

If an encoder fails, look up its FFmpeg option for forcing IDR frames
(`ffmpeg -h encoder=<name>`) and set it in `encoder_options`.
