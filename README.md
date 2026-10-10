![header](scripts/demo.png)

A sloppy chat and VOIP application.

- Single binary client and server (client about 8 MiB, server about 4 MiB)
- Runs on Linux, Windows, macOS (and optionally in a browser)
- Uses only UDP (WebSocket for web client)
- Minimal runtime dependencies (Basically only Glfw, some optional ones for extra features)
- Uses [noise protocol](https://noiseprotocol.org) for encryption between client and server\*
- Uses [RNN](https://github.com/xiph/rnnoise) and Opus (with three options 24kbit/s, 64kbit/s and 192kbit/s stereo)
- Channels to subscribe to, each with a chat and a voice room
- Persistent chats and DMs stored on server
- Client can join multiple servers
- File attachments
- Optional account registration via email confirmation
- Invite codes
- Optional server password; the client remembers the last 10 servers
- Basic user roles with permissions
- Per user direct chats with file transfers
- Message reactions
- Custom server emotes
- Per channel pinned messages
- Link and forward messages
- Screen sharing (low frame rate) between web clients (not for native clients)
- Global hotkeys (requires `input` group on wayland)
- Option to share audio of a specific application (native clients only)

## Running a server

```sh
yap-server               # or: yap-server path/to/config.json
```

The first run writes `config.json` (see `config.example.json`): the port,
the server's private key, an optional password, logging, the web relay
and the channels to start with (the first is the home channel everyone is
in; after the first start the channels live in the database, and the
owner makes more from the client's Channels window). Next to it, or in the config's `data_dir`, the
server keeps its database (`yap.db`) and a `blobs` folder.

People need an account to get in, and accounts are made by an admin. A
server that has none makes one called `admin` when it starts and writes its
password to the log, once; log in with that, choose a password of your
own, and make the others from the client's settings. The same can be done
without a client:

```sh
yap-server account list
yap-server account add <username>      # prints a first password
yap-server account passwd <username>   # a new one, if it was forgotten
```

\*I have no idea how encryption works
