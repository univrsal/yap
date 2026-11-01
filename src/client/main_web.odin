#+build wasi
package client

// The web build compiles src/client as an object file. This import pulls in the
// UI package, whose main_web.odin holds the exported entry points.
import _ "client:ui"
