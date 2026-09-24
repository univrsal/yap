# yap in a browser

The yap client, compiled to WebAssembly and running in a page: the same
UI, the same protocol, the same end-to-end encryption as the desktop
client. Text chat, channels, the user list and voice work.

## Running it

```sh
./build.sh                 # the server and the desktop client
./web/build.sh             # the web client, into web/out (needs emscripten)

bin/yap-server server.key -relay:8080
```

`-relay` turns on the relay (below) on that TCP port, alongside the
server; `-web` points it at a web build other than `web/out`.

Then open <http://localhost:8080/?server=localhost:7777>. The `server`
parameter connects straight away; without it the page starts on the
usual connect screen, where `localhost:7777` works as it does on a
desktop. `log=debug` (or `info`, `warn`, `error`) sets the log level,
like the desktop's `-log-level`; the log goes to the Log tab and the
browser's console.

## Why there's a relay

A browser can't send UDP, which is what yap speaks. So the web client
sends the same packets over a WebSocket, one packet per message, and the
server's relay (server/relay.odin, started with `-relay`) puts them back
on UDP - one UDP socket per browser, sent to the server over loopback,
so the server sees each as a client of its own. Past the relay, the
server handles browsers exactly as it does desktop clients.

The relay can't read what it carries: the Noise session runs between the
web client and the server, and the relay only ever sees sealed packets.
It only relays to its own server, whatever address the page names, so it
can't be used to send UDP anywhere else. It also serves the web build,
so one address is all a browser needs.

A page served over https may only open wss:// sockets, so a public
deployment puts the relay behind something that terminates TLS.

## What works, and what doesn't yet

Works: connecting, channels, the user list with everyone's speaking,
muted and deafened state, text chat and the pictures in it, links,
settings. The key, settings and known servers live in the page's local
storage, so a browser keeps its identity across visits.

Voice works as it does on a desktop: the microphone (the browser asks
for it the first time), noise suppression, the voice gate and the
quality presets on the way out, and everyone else's voice, decoded and
mixed, on the way in, with the notification sounds and listen back. A
browser only lets a page make sound once it has been clicked, so audio
that starts before that - connecting straight from `?server=` - begins
with the first click. Voice carries on while the tab is hidden.

Not yet:

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
- **High-DPI screens.** Emscripten's GLFW sizes the canvas' pixels as
  its CSS size times devicePixelRatio, rounded down, which at 125% or
  150% (or a zoomed page) is a pixel off what's on screen, and it misses
  the ratio changing after its first change. So the page sizes them
  itself, every frame, to the device pixels the browser says the canvas
  covers (yap_canvas_fit in shell.c); the window size stays in CSS
  pixels, so input is untouched.
- **Network.** client/transport.odin is the seam: UDP on a desktop, the
  WebSocket to the relay on the web. There are no threads in the page,
  so the network loop is stepped from the frame loop (client/net_web.odin),
  and so are picture decodes (client/ui_images_worker_web.odin). Nothing
  on the web side may wait on a semaphore or condition variable: without
  threads, Odin's futex panics.
- **In the background.** A browser stops drawing a hidden tab or a
  minimised window, and with the frames would go the connection and the
  voice. So a worker (web/background.js) ticks every 10 ms - a worker's
  timers aren't throttled the way a hidden page's are - and each tick
  calls web_tick (client/main_web.odin), which steps the network loop
  whenever no frame has run for 50 ms. Voice and the connection carry on
  in the background; drawing waits until the tab is shown.
- **Audio.** client/miniaudio/yap_audio.c is compiled by emscripten
  with miniaudio's Web Audio backend. It runs on ScriptProcessorNodes,
  which call back on the page's thread between frames, so the rings in
  voice_io.odin work as they do on a desktop. Being on the page's thread,
  a callback can be held up by anything else the page does, and Chrome
  plays silence for a period whose callback is late - with 10 ms periods
  that was a dropout every few seconds. So the web uses 40 ms periods
  (2048 frames, what Chrome would pick itself), and keeps a period and a
  frame queued for the output. `?audio_period=<ms>` (10 to 100) trades
  that back for latency, to try on a given machine. The microphone comes
  in 43 ms at a time too, so a browser sends its 20 ms frames two or
  three at once; whoever listens notices (client/voice.odin,
  track_arrival) and buffers a browser speaker a little longer - about
  80 ms rather than 40 - so its sentences don't start with a dropout.
- **Codecs.** RNNoise (client/rnn/yap_rnn.c) is compiled by emscripten
  like miniaudio. libopus is too big to keep in the repo, so the first
  web/build.sh fetches the release client/opus is bound against, checks
  its SHA-256 and builds it for wasm into web/deps/ (so that first build
  also needs curl and CMake); later builds reuse it.
- **Storage.** common/store.odin: files on a desktop, local storage on
  the web, under the same names.

## Testing it

The build is checked by loading it in headless Chromium against a real
server, with a desktop client in the same channel: the web client
connects through the relay, both see each other in the channel, and chat
goes both ways. For voice, the desktop client runs with `-headless
-tone:440` and Chromium with `--use-fake-device-for-media-stream
--use-file-for-fake-audio-capture=<a sine .wav>`: the desktop client
logs the browser's tone as heard, and the browser's `log=debug` voice
stats show the desktop's packets arriving. `odin test client` and `odin test proto` cover the
shared code as before.
