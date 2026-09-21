#+build wasi
package client

// The web build currently provides stub libopus functions, so notification
// samples intentionally remain silent until browser Opus decoding is added.
notifications_init :: proc(s: ^Notification_Sounds) {s.volume = 1}
notifications_destroy :: proc(s: ^Notification_Sounds) {s^ = {}}
notification_play :: proc(s: ^Notification_Sounds, kind: Notification_Kind) {}
notifications_mix :: proc(s: ^Notification_Sounds, mix: []f32) {}
