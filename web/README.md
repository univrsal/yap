# yap in a browser

The yap client, compiled to WebAssembly and running in a page: the same
UI, the same protocol, the same end-to-end encryption as the desktop
client. Text chat, channels and the user list work; voice doesn't yet.

## Running it

```sh
./build.sh                 # the server, the desktop client and yap-relay
./web/build.sh             # the web client, into web/out (needs emscripten)

bin/yap-server server.key
bin/yap-relay localhost:7777
```

Then open <http://localhost:8080/?server=localhost:7777>. The `server`
parameter connects straight away; without it the page starts on the
usual connect screen, where `localhost:7777` works as it does on a
desktop.

## Why there's a relay

A browser can't send UDP, which is what yap speaks. So the web client
sends the same packets over a WebSocket, one packet per message, and
`yap-relay` puts them back on UDP - one UDP socket per browser, so the
server sees each as a client of its own. The server needs no changes.

The relay can't read what it carries: the Noise session runs between the
web client and the server, and the relay only ever sees sealed packets.
It only relays to the servers it was started with (`yap-relay a:7777,b:7777`),
so it can't be used to send UDP anywhere else. It also serves the web
build, so one address is all a browser needs.

A page served over https may only open wss:// sockets, so a public
deployment puts the relay behind something that terminates TLS.

## What works, and what doesn't yet

Works: connecting, channels, the user list with everyone's speaking,
muted and deafened state, text chat, links, settings. The key, settings
and known servers live in the page's local storage, so a browser keeps
its identity across visits.

Not yet:

- **Voice.** libopus has to be built for wasm, and miniaudio's WebAudio
  backend needs the page to ask for the microphone and to run on an
  audio worklet. Until then web/audio_stub.c stands in for both, and the
  client behaves as it does on a machine with no sound card.
- **Pictures in chat.** stb_image isn't built for wasm here; a browser
  could decode them itself, but asynchronously. They show as pictures
  that couldn't be displayed.
- **Pasting pictures**, the **tray icon**, and **hiding to the tray**,
  none of which a page has.

## How it's put together

The desktop client is the same code; what a browser can't do is
switched off file by file with `#+build wasi` / `#+build !wasi`, and
`WEB` (client/web.odin) inside files where it's a line or two.

- **Target.** Odin compiles the client for `wasi_wasm32` as an object,
  and emscripten links it with the page's glue (shell.c), GLFW and
  WebGL. WASI rather than freestanding because that's where Odin has a
  clock and an entropy source, and the Noise handshake can't do without
  entropy; emscripten provides both, and wasi.js answers the few other
  WASI calls Odin's runtime makes. Since emscripten owns `main`,
  `web_start` runs Odin's start-up itself (client/main_web.odin).
- **Memory.** Everything allocates through emscripten's malloc
  (client/web_alloc.odin): Odin's own wasm allocator would grow the
  same memory behind malloc's back.
- **Wrappers.** A few packages are imported under their usual names but
  are thin layers that are the real thing on a desktop and a hand-written
  binding on the web: `wglfw` (GLFW), `wgl` (OpenGL/WebGL 2), `wstbtt`
  (stb_truetype), `common/wlog` (core:log, which doesn't build for
  WASI). The C libraries' declarations are split the same way;
  gen_foreign.py regenerates the web copies.
- **Network.** client/transport.odin is the seam: UDP on a desktop, the
  WebSocket to the relay on the web. There are no threads in the page,
  so the network loop is stepped from the frame loop (client/net_web.odin).
- **Storage.** common/store.odin: files on a desktop, local storage on
  the web, under the same names.

## Testing it

The build is checked by loading it in headless Chromium against a real
server, with a desktop client in the same channel: the web client
connects through the relay, both see each other in the channel, and chat
goes both ways. `odin test client` and `odin test proto` cover the
shared code as before.
