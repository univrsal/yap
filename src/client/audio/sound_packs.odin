package audio

import "base:runtime"
import "core:strings"

// The sounds built into the client, in packs: one folder each under
// assets/soundpacks, every file in it an Ogg Opus sound. A sound is named
// by its pack and its file name without the extension, as in "aim/msg".
// A file added to a pack's folder is part of the pack at the next build.
//
// The user picks the sound of every event (settings.sound_name): one of
// these, none, or a file of their own (sound_store.odin).

Sound_Pack :: struct {
	name:  string, // the folder's name, the first part of a sound's name
	label: string, // shown in the settings
	files: []runtime.Load_Directory_File,
}

SOUND_PACKS := [?]Sound_Pack {
	{"base", "Yap", #load_directory("../assets/soundpacks/base")},
	{"aim", "AIM", #load_directory("../assets/soundpacks/aim")},
	{"skype", "Skype", #load_directory("../assets/soundpacks/skype")},
	{"icq", "ICQ", #load_directory("../assets/soundpacks/icq")},
}

// The events that make a sound. None is no event: notification_loop(.None)
// stops the loop.
Sound_Event :: enum {
	None,
	// Messages.
	Message, // in a channel that notifies of every message
	Direct_Message, // a DM, and the DMs unread at login
	Mention,
	File_Offered, // somebody offers us a file in a DM (conn/files.odin)
	Done, // a file sent to us or our attachments are through
	// Voice.
	Join, // into the voice room our voice is in, ourselves included
	Leave,
	Muted, // our own mute or deafen toggles (voice_feedback_play)
	Unmuted,
	Deafened,
	Undeafened,
	Connection_Trouble, // the connection goes bad while in voice or a call
	Connection_Bad, // and stays bad: a loop
	// Calls. Ring, Ringback and Knock are loops.
	Ring, // an incoming call
	Knock, // an incoming call while our voice is busy, here or on another server
	Ringback, // our own outgoing call
	Call_Declined, // our call ends without being answered
	Call_Ended, // a call we are in ends
	// The client itself (ui_app_sounds.odin), not on the web.
	Welcome,
	Goodbye,
}

// The events the UI plays itself (ui_app_sounds.odin): a server's Voice
// doesn't hold their sounds.
APP_SOUNDS :: bit_set[Sound_Event]{.Welcome, .Goodbye}

Sound_Event_Info :: struct {
	key:   string, // in settings.json
	label: string, // in the settings
	loop:  bool, // played over and over until stopped (notification_loop)
}

SOUND_EVENTS := [Sound_Event]Sound_Event_Info {
	.None               = {},
	.Message            = {"message", "Message", false},
	.Direct_Message     = {"direct_message", "Direct message", false},
	.Mention            = {"mention", "Mention", false},
	.File_Offered       = {"file_offered", "File offered", false},
	.Done               = {"done", "Transfer done", false},
	.Join               = {"join", "Someone joins", false},
	.Leave              = {"leave", "Someone leaves", false},
	.Muted              = {"muted", "Muted", false},
	.Unmuted            = {"unmuted", "Unmuted", false},
	.Deafened           = {"deafened", "Deafened", false},
	.Undeafened         = {"undeafened", "Undeafened", false},
	.Connection_Trouble = {"connection_trouble", "Connection trouble", false},
	.Connection_Bad     = {"connection_bad", "Connection still bad", true},
	.Ring               = {"ring", "Incoming call", true},
	.Knock              = {"knock", "Call while in voice", true},
	.Ringback           = {"ringback", "Outgoing call", true},
	.Call_Declined      = {"call_declined", "Call not answered", false},
	.Call_Ended         = {"call_ended", "Call ended", false},
	.Welcome            = {"welcome", "Starting", false},
	.Goodbye            = {"goodbye", "Quitting", false},
}

// The sound of each event unless the user picked another: the Default pack.
// "" is no sound.
DEFAULT_SOUNDS := #partial [Sound_Event]string {
	.Ring       = "base/ring",
	.Ringback   = "base/ringback",
	.Knock      = "skype/knocking",
	.Muted      = "base/muted",
	.Unmuted    = "base/unmuted",
	.Deafened   = "base/muted",
	.Undeafened = "base/unmuted",
}

// What using a preset on the Sounds page does to the user's choices.
Sound_Preset_Kind :: enum {
	Default, // back to DEFAULT_SOUNDS: the user's choices are forgotten
	Quiet, // no sound for any event
	Pack, // the events in `sounds` get those; the others are left as they are
}

Sound_Preset :: struct {
	label:  string,
	kind:   Sound_Preset_Kind,
	sounds: [Sound_Event]string,
}

SOUND_PRESETS := [?]Sound_Preset {
	{label = "Default", kind = .Default},
	{label = "Quiet", kind = .Quiet},
	{
		label = "AIM",
		kind = .Pack,
		sounds = #partial [Sound_Event]string {
			.Message = "aim/msg",
			.Direct_Message = "aim/mail",
			.Mention = "aim/mail",
			.Done = "aim/done",
			.Join = "aim/join",
			.Leave = "aim/leave",
			.Welcome = "aim/welcome",
			.Goodbye = "aim/goodbye",
		},
	},
	{
		label = "Skype",
		kind = .Pack,
		sounds = #partial [Sound_Event]string {
			.Message = "skype/msg",
			.Direct_Message = "skype/msg",
			.Mention = "skype/msg",
			.File_Offered = "skype/incoming_file",
			.Done = "skype/done",
			.Connection_Trouble = "skype/reconnect",
			.Connection_Bad = "skype/reconnect_loop",
			.Ring = "skype/ring",
			.Knock = "skype/knocking",
			.Ringback = "skype/ringback",
			.Call_Declined = "skype/busy",
			.Call_Ended = "skype/hangup",
			.Welcome = "skype/login",
			.Goodbye = "skype/logout",
		},
	},
	{
		label = "ICQ",
		kind = .Pack,
		sounds = #partial [Sound_Event]string {
			.Message = "icq/message",
			.Direct_Message = "icq/message",
			.Mention = "icq/notify",
			.File_Offered = "icq/file",
			.Done = "icq/file_done",
			.Join = "icq/online",
			.Ring = "icq/ring",
			.Knock = "icq/knock",
			.Welcome = "icq/startup",
		},
	},
}

// sound_data returns the encoded data of a built-in sound, by its name
// ("aim/msg").
sound_data :: proc(name: string) -> (data: []u8, ok: bool) {
	pack, _, file := strings.partition(name, "/")
	for p in SOUND_PACKS {
		if p.name != pack {
			continue
		}
		for f in p.files {
			if strings.trim_suffix(f.name, ".opus") == file {
				return f.data, true
			}
		}
	}
	return nil, false
}

// sound_label is a built-in sound's name as the settings show it, as in
// "Skype: reconnect loop". The result is in the temp allocator.
sound_label :: proc(name: string) -> string {
	pack, _, file := strings.partition(name, "/")
	label := pack
	for p in SOUND_PACKS {
		if p.name == pack {
			label = p.label
		}
	}
	file, _ = strings.replace_all(file, "_", " ", context.temp_allocator)
	return strings.concatenate({label, ": ", file}, context.temp_allocator)
}
