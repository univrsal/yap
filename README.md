![header](scripts/demo.png)

A sloppy, minimal and limited VOIP application.

- Single binary client and server (client about 3.8 MiB, server about 2.0)
- Server can optionally also host web client to use it in a browser
- Uses only UDP (WebSocket for web client)
- Minimal runtime dependencies (Mostly only Glfw)
- Uses [noise protocol](https://noiseprotocol.org) for encryption between client and server*
- Builtin [RNN](https://github.com/xiph/rnnoise) for noise reduction
- Opus as audio codec with three per user quality options: 24kbit/s, 64kbit/s and 128kbit/s stereo
- Simple per channel chat, retains the last 50 messages per channel
- Paste images from clipboard into chat
- Per user volumes, muting and poking
- No permission system

*I have no idea how encryption works
