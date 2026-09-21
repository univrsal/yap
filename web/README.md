# yap in a browser

The yap client, compiled to WebAssembly and running in a page: the same
UI, the same protocol, the same end-to-end encryption as the desktop
client. Text chat, channels and the user list work; for voice, the
microphone and speakers do, but nothing is sent or heard from others
yet.

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
desktop. `log=debug` (or `info`, `warn`, `error`) sets the log level,
like the desktop's `-log-level`; the log goes to the Log tab and the
browser's console.

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
muted and deafened state, text chat and the pictures in it, links,
settings. The key, settings and known servers live in the page's local
storage, so a browser keeps its identity across visits.

Audio devices work, through miniaudio's Web Audio backend: the
microphone (the browser asks for it the first time), its level meter and
the voice gate, and the speakers, which listen back plays through. A
browser only lets a page make sound once it has been clicked, so audio
that starts before that - connecting straight from `?server=` - begins
with the first click.

Not yet:

- **Sending and hearing voice.** libopus has to be built for wasm; until
  then web/audio_stub.c stands in for it, and the client captures and
  plays but neither encodes nor decodes. Who's speaking still shows.
- **Noise suppression.** RNNoise needs its header to travel with it (the
  desktop build finds it among the system's), so it's stubbed too and
  the setting is hidden.
- **Audio in a background tab.** The client mixes from the page's frame
  loop, which a browser pauses in a hidden tab; the sound stops until
  the tab is shown again. Moving the pipeline onto an audio worklet
  would fix that, but needs threads (and cross-origin isolation).
- **Sending and saving pictures.** Pictures others post show up, but
  pasting one needs the browser's clipboard API, and saving one a
  download the page starts.
- The **tray icon** and **hiding to the tray**, which a page doesn't have.

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
  (stb_truetype), `wstbi` (stb_image), `common/wlog` (core:log, which
  doesn't build for WASI). The C libraries' declarations are split the
  same way; gen_foreign.py regenerates the web copies.
- **Network.** client/transport.odin is the seam: UDP on a desktop, the
  WebSocket to the relay on the web. There are no threads in the page,
  so the network loop is stepped from the frame loop (client/net_web.odin),
  and so are picture decodes (client/ui_images_worker_web.odin). Nothing
  on the web side may wait on a semaphore or condition variable: without
  threads, Odin's futex panics.
- **Audio.** client/miniaudio/yap_audio.c is compiled by emscripten
  with miniaudio's Web Audio backend. It runs on ScriptProcessorNodes,
  which call back on the page's thread between frames, so the rings in
  voice_io.odin work as they do on a desktop. The output keeps 60 ms
  queued rather than 30, since it's topped up once per frame.
- **Storage.** common/store.odin: files on a desktop, local storage on
  the web, under the same names.

## Testing it

The build is checked by loading it in headless Chromium against a real
server, with a desktop client in the same channel: the web client
connects through the relay, both see each other in the channel, and chat
goes both ways. `odin test client` and `odin test proto` cover the
shared code as before.
