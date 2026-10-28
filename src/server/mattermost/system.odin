package mattermost

import "core:encoding/json"
import "core:strings"

import "common:proto"

// System posts: Mattermost's "alice joined the channel" and the like, which
// become yap's own system messages (step 4, proto.Conv_System). The table in
// the design note ("System messages") says which; this is it as code.

System_Result :: enum {
	Not_System, // an ordinary post (or one of a bot's), to be imported as text
	Mapped, // becomes the System_Post
	Dropped, // a system post that yap has no use for; left out, and counted by type
	Incomplete, // one that would map, but the export doesn't say enough; left out and reported
	Unknown, // a system_ type that isn't known; left out and reported
}

// System_Post is the system message that a post becomes.
System_Post :: struct {
	what: proto.Conv_System,
	// The username it was done to, for Added and Removed; "" for the rest.
	arg:  string,
	// Whose message it is when that isn't the post's author: a joining or a
	// leaving of the team is the account's own, whoever posted it.
	who:  string,
	// What changed: the old value and the new one, a line each; or "".
	text: string,
}

// Types that are Mattermost's own bookkeeping, or were never stored as a post
// that anyone read. They are left out.
@(private = "file")
DROPPED :: [?]string {
	"system_generic",
	"system_ephemeral",
	"system_auto_responder",
	"system_wrangler",
	"system_move_channel",
	"system_gm_to_channel",
	"add_bot_teams_channels",
	"system_join_leave",
	"system_add_remove",
}

// map_system works out what a post of type `type` becomes. `message` is its
// text and `props` its props. `channel_has_header` says whether the channel it
// is in has a header now, which decides whether a change of purpose is the
// channel's topic changing (see system_purpose_change below). The strings of
// the result are allocated with `allocator`.
map_system :: proc(
	type, message: string,
	props: json.Value,
	channel_has_header: bool,
	allocator: Allocator,
) -> (
	p: System_Post,
	result: System_Result,
) {
	if !strings.has_prefix(type, "system_") && type != "add_bot_teams_channels" {
		return {}, .Not_System
	}
	for d in DROPPED {
		if type == d {
			return {}, .Dropped
		}
	}
	result = .Mapped
	switch type {
	case "system_join_channel", "system_guest_join_channel":
		p.what = .Joined
	case "system_leave_channel":
		p.what = .Left
	case "system_add_to_channel", "system_add_guest_to_chan":
		p.what = .Added
		p.arg = prop(props, "addedUsername", allocator)
		if p.arg == "" {
			return {}, .Incomplete
		}
	case "system_remove_from_channel":
		p.what = .Removed
		p.arg = prop(props, "removedUsername", allocator)
		if p.arg == "" {
			return {}, .Incomplete
		}
	case "system_displayname_change":
		p.what = .Renamed
		p.text = change(
			prop(props, "old_displayname", context.temp_allocator),
			prop(props, "new_displayname", context.temp_allocator),
			proto.MAX_CHANNEL_NAME_SIZE,
			allocator,
		)
	case "system_header_change":
		p.what = .Topic_Changed
		p.text = change(
			prop(props, "old_header", context.temp_allocator),
			prop(props, "new_header", context.temp_allocator),
			proto.MAX_TOPIC_SIZE,
			allocator,
		)
	case "system_purpose_change":
		// The channel's topic is its header, or its purpose if it has no header
		// (topic_of), so the purpose is only a topic that changed in that case.
		if channel_has_header {
			return {}, .Dropped
		}
		p.what = .Topic_Changed
		p.text = change(
			prop(props, "old_purpose", context.temp_allocator),
			prop(props, "new_purpose", context.temp_allocator),
			proto.MAX_TOPIC_SIZE,
			allocator,
		)
	case "system_change_chan_privacy":
		// Only the text says which way it went, and it does in the server's
		// language. A text that isn't English is reported, and the caller can
		// work it out from the channel's current type.
		switch {
		case strings.contains(message, "Private Channel"):
			p.what = .Made_Private
		case strings.contains(message, "Public Channel"):
			p.what = .Made_Public
		case:
			return {}, .Incomplete
		}
	case "system_channel_deleted":
		p.what = .Archived
	case "system_channel_restored":
		p.what = .Unarchived
	case "system_join_team":
		p.what = .Joined_Server
	case "system_add_to_team":
		// The account that was added is the one the message is about.
		p.what = .Joined_Server
		p.who = prop(props, "addedUsername", allocator)
	case "system_leave_team":
		p.what = .Left_Server
	case "system_remove_from_team":
		p.what = .Left_Server
		p.who = prop(props, "removedUsername", allocator)
	case:
		return {}, .Unknown
	}
	return
}

// prop returns a string prop, or "".
@(private = "file")
prop :: proc(props: json.Value, key: string, allocator: Allocator) -> string {
	if obj, ok := props.(json.Object); ok {
		if v, there := obj[key]; there {
			if s, is_string := v.(json.String); is_string {
				return strings.clone(s, allocator)
			}
		}
	}
	return ""
}

// change writes the old and the new value as a system message's text holds
// them: a line each, and each a single line cut to `limit`.
@(private = "file")
change :: proc(old, new: string, limit: int, allocator: Allocator) -> string {
	o, _ := clean_text(old, limit)
	n, _ := clean_text(new, limit)
	return strings.concatenate({o, "\n", n}, allocator)
}
