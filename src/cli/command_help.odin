package main

import "core:fmt"
import "core:slice"
import "core:strings"

import "tui"

// What the commands are called, what they take and what they do: shown while a
// command is completed, as a hint while its arguments are typed, by
// /help <command> and /help commands, and when a command is used without what it
// needs.
//
// `args` is written the way a usage line is: <name> must be given, [name] may
// be left out, a|b is a choice. The arguments are told apart by spaces, except
// that the last <argument> takes the rest of the line.

Command_Doc :: struct {
	name:    string,
	args:    string,
	help:    string,
	example: string,
}


COMMAND_DOCS := [?]Command_Doc {
	// Looking around
	{"join", "<channel>", "Look at a channel (# is optional). Ctrl+K and Alt+Up/Down get you there too.", "/join general"},
	{"channels", "", "List your channels, what is unread in them and who is talking.", ""},
	{"browse", "[text]", "List the channels you can subscribe to; /browse more shows the next page.", "/browse dev"},
	{"subscribe", "<channel>", "Subscribe to a channel you found with /browse.", ""},
	{"unsubscribe", "<channel>", "Leave a channel's list (you can subscribe again later).", ""},
	{"create", "<channel> [topic]", "Create a channel, if you may.", "/create ideas Things to try"},
	{"private", "<name>", "Create a private channel.", ""},
	{"notify", "<channel> all|mentions|none", "How much a channel may interrupt you.", "/notify general mentions"},
	{"members", "", "List who is in this conversation.", ""},
	{"older", "", "Fetch the page of messages before those shown.", ""},
	{"newer", "", "Fetch the page of messages after those shown.", ""},
	{"jump", "<id>", "Show the messages around a message (the ids are the #numbers in the chat).", ""},
	{"search", "[all] <words>", "Search this conversation, or all of them with \"all\". /search more: the next page.", "/search all lunch"},
	{"pins", "", "List the pinned messages of this conversation.", ""},
	{"bookmarks", "[more]", "List your bookmarks.", ""},
	// Messages
	{"say", "<text>", "Send text as a message (what you type without a / does the same). \\n starts a new line.", ""},
	{"reply", "<id> <text>", "Answer in a message's thread. Or pick the message with Tab and press r.", "/reply 42 sounds good"},
	{"edit", "<id> <text>", "Change one of your messages. Or press Up in an empty box.", "/edit 42 fixed typo"},
	{"delete", "<id>", "Delete a message (yours, or anyone's if you may).", ""},
	{"react", "<id> <emoji>", "Add a reaction to a message. The emoji can be a character, :shortcode: or :name:.", "/react 42 :thumbsup:"},
	{"unreact", "<id> <emoji>", "Remove your reaction from a message.", ""},
	{"pin", "<id>", "Pin a message to the conversation.", ""},
	{"unpin", "<id>", "Unpin a message.", ""},
	{"bookmark", "<id>", "Bookmark a message, for you only.", ""},
	{"unbookmark", "<id>", "Remove a bookmark.", ""},
	{"thread", "<id>", "Open a message's thread beside the chat.", ""},
	{"unthread", "<id>", "Close a thread.", ""},
	{"forward", "<id> <channel>", "Forward a message to one of your channels.", "/forward 42 random"},
	{"attach", "<file>", "Attach a file to your next message (up to 10). /unattach takes them off again.", "/attach ~/pic.png"},
	{"unattach", "", "Take the attached files off the next message.", ""},
	{"save", "<id> <n>", "Save file n of a message to the downloads folder.", "/save 42 1"},
	{"typing", "[id]", "Tell the others that you are typing.", ""},
	{"emoji", "", "Open the emoji picker (type to search). The same as F3.", ""},
	// People
	{"dm", "<name> [text]", "Open the DMs with someone, and write to them if there is text.", "/dm anna hello!"},
	{"group", "<name>,<name>,...", "Open a group chat with 2 to 7 people, or start it.", "/group anna,ben"},
	{"buddies", "", "List your buddies, DMs and groups.", ""},
	{"buddy", "<name>", "Add someone to your buddies.", ""},
	{"unbuddy", "<name>", "Remove someone from your buddies.", ""},
	{"seen", "<name>", "Ask when someone was last on the server.", ""},
	{"status", "[minutes] [text]", "Set your status; it expires after that many minutes. Alone: clear it.", "/status 60 at lunch"},
	{"activity", "online|away|busy|offline", "Set how you show up on all your devices.", ""},
	{"name", "<name>", "Change your display name.", ""},
	{"avatar", "<file>", "Use a picture as your profile picture. /noavatar removes it.", ""},
	{"set", "<key> <value>", "Change one of your account's settings.", ""},
	{"unset", "<key>", "Reset one of your account's settings.", ""},
	{"email", "[address]", "Set your email address; without one, remove it.", ""},
	{"digest", "none|missed|mentions", "What the server emails you about what you missed.", ""},
	{"passwd", "<old> <new>", "Change your password.", ""},
	{"devices", "", "List your devices (also: Ctrl+K).", ""},
	{"revoke", "<key>", "Log out a device, given the key /devices shows.", ""},
	{"logout", "", "Log this device out.", ""},
	// Calls and voice
	{"call", "<name>", "Call someone. Or click them in the member list, or press Call in a DM.", "/call anna"},
	{"answer", "", "Accept the incoming call (A answers it as well).", ""},
	{"hangup", "", "End the call, or cancel or decline it.", ""},
	{"voice", "[channel]", "Join the voice room of this channel or of another one; leave it again when you are in it.", "/voice lounge"},
	{"novoice", "", "Leave the voice room.", ""},
	{"leave", "", "Leave the voice room.", ""},
	{"mute", "", "Stop sending your voice (F5).", ""},
	{"unmute", "", "Send your voice again.", ""},
	{"deafen", "", "Stop hearing the others (F6).", ""},
	{"undeafen", "", "Hear the others again.", ""},
	{"cameras", "[names]", "Watch these people's cameras (none: stop).", ""},
	// Files between people
	{"file", "<name> <file>", "Offer a file to someone in a DM (they have to be online).", "/file anna ~/notes.zip"},
	{"accept", "", "Accept the files that are offered to you.", ""},
	{"decline", "", "Decline the files that are offered to you.", ""},
	{"cancel", "", "Stop every file transfer.", ""},
	// Servers
	{"servers", "", "List the servers you are connected to (Ctrl+N / Ctrl+P switch).", ""},
	{"server", "[number|name]", "Switch to another server.", "/server 2"},
	{"connect", "<host[:port]> [password]", "Connect to another server, and remember it.", "/connect chat.example.org:7777"},
	{"disconnect", "[number|name]", "Leave a server and forget it (the current one if you give none).", ""},
	{"settings", "", "Open the settings (F9).", ""},
	// Admin
	{"roles", "", "List the server's roles and who has them.", ""},
	{"mkrole", "<name> [permission,...]", "Create a role.", "/mkrole mods Pin_Messages,Manage_Messages"},
	{"setrole", "<name> [permission,...]", "Change a role's permissions.", ""},
	{"delrole", "<name>", "Delete a role.", ""},
	{"assign", "<name> [role,...]", "Give someone exactly these roles.", "/assign anna mods,writers"},
	{"disable", "<name>", "Stop someone from logging in.", ""},
	{"enable", "<name>", "Let someone log in again.", ""},
	{"servermute", "<name>", "Mute someone for everyone on the server.", ""},
	{"serverunmute", "<name>", "Lift a server mute.", ""},
	{"voicemove", "<name> <channel>", "Move someone's voice to another room.", ""},
	{"voicekick", "<name>", "Remove someone from voice.", ""},
	{"ban", "<name> [reason]", "Ban someone; they are told the reason.", "/ban troll spamming"},
	{"unban", "<name>", "Lift a ban.", ""},
	{"bans", "", "List the bans.", ""},
	{"banpurge", "<name> hour|day|week|all [reason]", "Ban someone and remove their recent messages.", ""},
	{"purgeuser", "<name> [days]", "Remove someone's messages everywhere, of the last few days or all.", ""},
	{"deluser", "<name>", "Delete someone's account.", ""},
	{"adduser", "<username> <password> [name]", "Create an account.", ""},
	{"setpass", "<username> <password>", "Set a new password for an account.", ""},
	{"purge", "here|all <days> [files]", "Permanently remove the messages (or just their files) older than that.", "/purge here 90"},
	{"invite", "[uses] [days] | <name>", "Make an invite code (0 = no limit), or add someone to this private channel.", "/invite 5 7"},
	{"invites", "", "List the invite codes. /uninvite <code> revokes one.", ""},
	{"kick", "<name>", "Remove someone from this private channel.", ""},
	{"admin", "<name>", "Make someone an admin of this channel.", ""},
	{"unadmin", "<name>", "Take that away again.", ""},
	{"topic", "<text>", "Set this channel's topic.", ""},
	{"rename", "<name>", "Rename this channel.", ""},
	{"move", "<position>", "Move this channel in the list.", ""},
	{"archive", "", "Archive this channel.", ""},
	{"default", "on|off", "Whether new members join this channel.", ""},
	{"textonly", "on|off", "Whether this channel has no voice room.", ""},
	{"rights", "[<role>=<right,...> ...]", "Show what each role may do here, or replace it. Rights: see, write, attach, react, edit, delete, voice, speak, video, none.", "/rights everyone=see,react writers=see,write"},
	// The program
	{"help", "[command|commands]", "The keys; /help <command> tells how a command is used; /help commands lists them.", ""},
	{"quit", "", "Leave (Ctrl+C does too).", ""},
}

// command_doc finds a command's entry by its name, without the slash.
command_doc :: proc(name: string) -> (^Command_Doc, bool) {
	for &d in COMMAND_DOCS {
		if d.name == name {
			return &d, true
		}
	}
	return nil, false
}

// usage_line is how a command is written: /ban <name> [reason]
usage_line :: proc(d: Command_Doc) -> string {
	if d.args == "" {
		return strings.concatenate({"/", d.name}, context.temp_allocator)
	}
	return strings.concatenate({"/", d.name, " ", d.args}, context.temp_allocator)
}

// required_args says how many arguments must be given: those written <like this>
// at the start of the usage.
required_args :: proc(d: Command_Doc) -> (n: int) {
	for word in strings.fields(d.args, context.temp_allocator) {
		if !strings.has_prefix(word, "<") || strings.contains(word, "|") {
			break
		}
		n += 1
	}
	return
}

// missing_args says whether a command was used with fewer arguments than it
// needs; `rest` is what follows its name.
missing_args :: proc(d: Command_Doc, rest: string) -> bool {
	need := required_args(d)
	return need > 0 && len(strings.fields(rest, context.temp_allocator)) < need
}

// command_help is the text of /help <command>.
command_help :: proc(d: Command_Doc) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "%s", usage_line(d))
	fmt.sbprintfln(&b, "")
	fmt.sbprintfln(&b, "%s", d.help)
	if d.example != "" {
		fmt.sbprintfln(&b, "")
		fmt.sbprintfln(&b, "Example: %s", d.example)
	}
	fmt.sbprintfln(&b, "")
	fmt.sbprintf(&b, "<x> must be given, [x] may be left out, a|b is a choice.")
	return strings.to_string(b)
}

// commands_help lists every command with its usage and what it does.
commands_help :: proc() -> string {
	docs := make([]Command_Doc, len(COMMAND_DOCS), context.temp_allocator)
	copy(docs, COMMAND_DOCS[:])
	slice.sort_by(docs, proc(a, b: Command_Doc) -> bool {return a.name < b.name})
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "Type / to complete a command; /help <command> says more. <x> must be given, [x] may be left out.")
	for d in docs {
		fmt.sbprintfln(&b, "")
		fmt.sbprintfln(&b, "%s", usage_line(d))
		fmt.sbprintfln(&b, "    %s", d.help)
	}
	return strings.to_string(b)
}

// command_hint works out which command is being typed with its arguments (the
// text is `/name ` and more) and which argument the cursor is in.
command_hint :: proc(text: string, cursor: int) -> (d: ^Command_Doc, arg: int, ok: bool) {
	if !strings.has_prefix(text, "/") || strings.has_prefix(text, "//") || strings.contains(text, "\n") {
		return
	}
	space := strings.index_byte(text, ' ')
	if space < 0 || cursor <= space {
		return
	}
	d, ok = command_doc(strings.to_lower(text[1:space], context.temp_allocator))
	if !ok {
		return
	}
	// The argument is the number of spaces between words before the cursor.
	words := strings.fields(text[space:cursor], context.temp_allocator)
	arg = len(words)
	if cursor > 0 && text[cursor - 1] != ' ' && arg > 0 {
		arg -= 1
	}
	return
}

// draw_command_hint writes the usage of the command being typed, with the
// argument that the cursor is in in bold, and what the command does after it.
draw_command_hint :: proc(a: ^App, b: ^tui.Buffer, r: tui.Rect) -> bool {
	d, arg, ok := command_hint(tui.editor_text(&a.editor), a.editor.cursor)
	if !ok {
		return false
	}
	x := tui.put_string(b, r.x + 1, r.y, strings.concatenate({"/", d.name}, context.temp_allocator), theme.dim, r.x + r.w)
	args := strings.fields(d.args, context.temp_allocator)
	// A usage word with a space inside (the last one takes the rest) counts once.
	for word, i in args {
		style := tui.Style{attrs = {.Bold}} if i == min(arg, len(args) - 1) else theme.dim
		x = tui.put_string(b, x + 1, r.y, word, style, r.x + r.w)
	}
	tui.put_string(b, x + 2, r.y, strings.concatenate({"— ", d.help}, context.temp_allocator), theme.dim, r.x + r.w)
	return true
}
