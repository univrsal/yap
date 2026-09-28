#+build wasi
package client

/*
A page can't capture another application's audio (a browser only offers
a tab's, alongside sharing it), so a web build has no application audio
and no button for it. See app_audio_native.odin.
*/

UI_App_Audio :: struct {}

app_audio_init :: proc(ui: ^UI) {}
app_audio_destroy :: proc(ui: ^UI) {}
app_audio_available :: proc(ui: ^UI) -> bool {return false}
app_audio_frame :: proc(ui: ^UI) {}
app_audio_stop :: proc(ui: ^UI) {}
app_audio_button :: proc(ui: ^UI) {}
app_audio_menu :: proc(ui: ^UI) {}
