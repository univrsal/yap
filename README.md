![header](scripts/demo.png)

A sloppy, minimal and limited VOIP application.

- Single binary client and server (client about 4 MiB, server about 2.2)
- Runs on Linux, Windows, macOS (and optionally in a browser)
- Uses only UDP (WebSocket for web client)
- Minimal runtime dependencies (Mostly only Glfw)
- Uses [noise protocol](https://noiseprotocol.org) for encryption between client and server\*
- Uses [RNN](https://github.com/xiph/rnnoise) and Opus (with three options 24kbit/s, 64kbit/s and 192kbit/s stereo)
- Simple per channel chat, retains the last 50 messages per channel
- Paste images from clipboard into chat
- Per user volumes, muting and poking
- Optional server password; the client remembers the last 10 servers
- No permission system
- Per user direct chats with file transfers
- Screen sharing (low frame rate) between web clients (not for native clients)
- Global hotkeys (requires `input` group on wayland)
- Option to share audio of a specific application (native clients only)

## Running a server

```sh
yap-server               # or: yap-server path/to/config.json
```

The first run writes `config.json` (see `config.example.json`): the port,
the server's private key, an optional password, logging, the web relay
and the channel layout.

\*I have no idea how encryption works
