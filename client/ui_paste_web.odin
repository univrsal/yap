#+build wasi
package client

/*
Pasting a picture into the chat reads the clipboard on a thread, and a
page can only read the clipboard inside the paste event the user caused
- neither fits a web build yet (see clipboard/clipboard_web.odin). Text
still pastes into the chat box as usual.
*/

Paste_Job :: struct {}

paste_start :: proc(ui: ^UI) {}
paste_poll :: proc(ui: ^UI) {}
paste_wait :: proc(ui: ^UI) {}
