package client

/*
WEB is true in a build meant for a browser: Odin compiled to wasm and
linked with emscripten, where there is a canvas instead of a window, a
WebSocket instead of a UDP socket, and no threads at all.

The desktop client is the same code with none of that taken away; what
a browser can't do is switched off behind this, file by file, rather
than forked into a second client.
*/
WEB :: ODIN_OS == .WASI
