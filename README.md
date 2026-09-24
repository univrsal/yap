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
- Optional server password; the client remembers the last 10 servers
- No permission system

## Running a server

```sh
yap-server               # or: yap-server path/to/config.json
```

The first run writes `config.json` (see `config.example.json`): the port,
the server's private key, an optional password, logging, the web relay
and the channel layout. A `server.key` and `channels.json` from older
versions are taken over into it, so clients keep trusting the server.
The file holds the private key, so keep it private.

*I have no idea how encryption works
