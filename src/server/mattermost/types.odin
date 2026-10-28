package mattermost

import "core:encoding/json"

// The lines of a Mattermost bulk export (import.jsonl), as far as the importer
// reads them (docs/design/mattermost-import.md, "The export"). They follow
// server/channels/app/imports/import_types.go. Fields that the export doesn't
// have or that are null come out as zero values, and fields that aren't here
// are skipped, so a newer export still reads.

// The lines are one JSON object each, `{"type": "<kind>", "<kind>": {...}}`.
Line_Kind :: enum {
	Unknown,
	Version,
	Role,
	Scheme,
	Team,
	Channel,
	User,
	Bot,
	Post,
	Emoji,
	Direct_Channel,
	Direct_Post,
	// extras.jsonl (tools/mattermost/extras.py): what the export misses.
	Direct_Post_Reactions,
}

// line_kind_of returns the kind that a line's "type" names.
line_kind_of :: proc(name: string) -> Line_Kind {
	switch name {
	case "version":
		return .Version
	case "role":
		return .Role
	case "scheme":
		return .Scheme
	case "team":
		return .Team
	case "channel":
		return .Channel
	case "user":
		return .User
	case "bot":
		return .Bot
	case "post":
		return .Post
	case "emoji":
		return .Emoji
	case "direct_channel":
		return .Direct_Channel
	case "direct_post":
		return .Direct_Post
	case "direct_post_reactions":
		return .Direct_Post_Reactions
	}
	return .Unknown
}

// The version of the export format that this reader knows.
EXPORT_VERSION :: 1

Version_Info :: struct {
	generator: string,
	version:   string, // "10.12.4 (463e0d0d..., enterprise: false)"
	created:   string,
}

Version_Line :: struct {
	version: int,
	info:    Version_Info,
}

Team :: struct {
	name:         string,
	display_name: string,
	type:         string, // "O" open, "I" invite only
	description:  string,
}

Channel :: struct {
	team:         string,
	name:         string,
	display_name: string,
	type:         string, // "O" open, "P" private
	header:       string,
	purpose:      string,
	scheme:       string,
	deleted_at:   i64, // archived, in Unix milliseconds
}

Notify_Props :: struct {
	desktop:     string, // default, all, mention, none
	mobile:      string,
	mark_unread: string, // all, mention
}

// Channel_Member is what a user's line says about their membership of one
// channel.
Channel_Member :: struct {
	name:           string, // the channel's name
	roles:          string, // "channel_user channel_admin"
	notify_props:   Notify_Props,
	favorite:       bool,
	last_viewed_at: i64,
	msg_count:      i64,
	mention_count:  i64,
}

Team_Member :: struct {
	name:     string, // the team's name
	roles:    string, // "team_user team_admin"
	channels: []Channel_Member,
}

User :: struct {
	username:      string,
	email:         string,
	auth_service:  string, // "" for a password, otherwise the SSO provider
	nickname:      string,
	first_name:    string,
	last_name:     string,
	position:      string,
	roles:         string, // "system_user system_admin system_guest"
	locale:        string,
	delete_at:     i64, // deactivated, in Unix milliseconds
	profile_image: string, // a path under data/
	teams:         []Team_Member,
}

Bot :: struct {
	username:      string,
	owner:         string,
	display_name:  string,
	description:   string,
	delete_at:     i64,
	profile_image: string,
}

Reaction :: struct {
	user:       string,
	emoji_name: string,
	create_at:  i64,
}

Attachment :: struct {
	path: string, // under data/
}

// Reply is a post inside the `replies` of its thread's first post.
Reply :: struct {
	user:        string,
	type:        string, // "" for a post, "system_..." for a system message
	message:     string,
	props:       json.Value,
	create_at:   i64,
	edit_at:     i64,
	is_pinned:   bool,
	flagged_by:  []string, // who saved it
	reactions:   []Reaction,
	attachments: []Attachment,
}

Post :: struct {
	team:        string,
	channel:     string,
	user:        string,
	type:        string,
	message:     string,
	props:       json.Value,
	create_at:   i64,
	edit_at:     i64,
	is_pinned:   bool,
	flagged_by:  []string,
	reactions:   []Reaction,
	attachments: []Attachment,
	replies:     []Reply,
}

Direct_Member :: struct {
	username:       string,
	notify_props:   Notify_Props,
	last_viewed_at: i64,
	mention_count:  i64,
}

// Direct_Channel is a DM (two members, one twice for a DM with oneself) or a
// group message (three to eight).
Direct_Channel :: struct {
	participants: []Direct_Member,
}

Direct_Post :: struct {
	channel_members: []string, // the usernames of the direct channel's members
	user:            string,
	type:            string,
	message:         string,
	props:           json.Value,
	create_at:       i64,
	edit_at:         i64,
	is_pinned:       bool,
	flagged_by:      []string,
	reactions:       []Reaction,
	attachments:     []Attachment,
	replies:         []Reply,
}

Emoji :: struct {
	name:  string,
	image: string, // a path under data/
}

// Direct_Post_Reactions are the reactions to the first post of a DM or group
// message, which the export leaves out (extras.jsonl). The post is named as a
// direct post is.
Direct_Post_Reactions :: struct {
	channel_members: []string,
	user:            string,
	create_at:       i64,
	reactions:       []Reaction,
}

// The wrappers that a line is read into: `{"type": ..., "<kind>": {...}}`.
Version_Wrapper :: struct {
	version: int,
	info:    Version_Info,
}
Team_Wrapper :: struct {
	team: Team,
}
Channel_Wrapper :: struct {
	channel: Channel,
}
User_Wrapper :: struct {
	user: User,
}
Bot_Wrapper :: struct {
	bot: Bot,
}
Post_Wrapper :: struct {
	post: Post,
}
Direct_Channel_Wrapper :: struct {
	direct_channel: Direct_Channel,
}
Direct_Post_Wrapper :: struct {
	direct_post: Direct_Post,
}
Emoji_Wrapper :: struct {
	emoji: Emoji,
}
Direct_Post_Reactions_Wrapper :: struct {
	direct_post_reactions: Direct_Post_Reactions,
}
