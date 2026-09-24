A sloppy, minimal and limited VOIP application.

- Single binary client and server (client about 3.8 MiB, server about 2.0)
- Server can optionally also host web client to use it in a browser
- Uses only UDP (WebSocket for web client)
- Minimal runtime dependencies (Mostly only Glfw)
- Uses [noise protocol](https://noiseprotocol.org) for encryption between client and server*

*I have no idea how encryption works
