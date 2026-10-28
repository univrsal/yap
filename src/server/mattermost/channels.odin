package mattermost

import "core:strings"

import "common:proto"

// Channels, members and accounts' roles: what each of Mattermost's settings
// becomes in yap (docs/design/mattermost-import.md, "Mapping").

// The channels that Mattermost makes in every team: the one everybody is in,
// and the one they are subscribed to.
HOME_CHANNEL :: "town-square"
DEFAULT_CHANNEL :: "off-topic"

// Channel_Plan is what a channel becomes.
Channel_Plan :: struct {
	name:         string, // yap's channel name, which is unique
	topic:        string,
	flags:        proto.Conv_Flags, // Private, Archived, Default, Text_Only; never Home
	home:         bool, // it is the home channel, which the server has already
	from_purpose: bool, // the topic is the channel's purpose, as it has no header
	cut_name:     bool, // the name was cut to the limit
	cut_topic:    bool,
	renamed:      bool, // the name isn't the display name, as another channel has it
}

// plan_channels works out what each of a team's channels becomes, in the order
// they are given. Names are unique, ignoring case: the display name is the
// name, and when another channel already has it, a number is added, the active
// channels being given their names before the archived ones, which are the ones
// that people mind less.
plan_channels :: proc(channels: []Channel, allocator: Allocator) -> []Channel_Plan {
	plans := make([]Channel_Plan, len(channels), allocator)
	names := unique_make(.Parens, allocator)
	for pass in 0 ..< 2 {
		for c, i in channels {
			if (c.deleted_at != 0) == (pass == 1) {
				plans[i] = plan_channel(c, &names, allocator)
			}
		}
	}
	return plans
}

// plan_channel is plan_channels for one channel, with the names that have been
// taken so far.
plan_channel :: proc(c: Channel, names: ^Unique, allocator: Allocator) -> (p: Channel_Plan) {
	archived := c.deleted_at != 0
	public := c.type != "P"
	wanted, cut := clean_text(c.display_name, proto.MAX_CHANNEL_NAME_SIZE)
	p.cut_name = cut
	if wanted == "" {
		wanted, p.cut_name = clean_text(c.name, proto.MAX_CHANNEL_NAME_SIZE)
	}
	if wanted == "" {
		wanted = "channel"
	}
	p.name = unique_name(names, wanted, proto.MAX_CHANNEL_NAME_SIZE)
	p.renamed = p.name != wanted
	topic: string
	topic, p.from_purpose = topic_of(c)
	text, cut_topic := clean_text(topic, proto.MAX_TOPIC_SIZE)
	p.topic = strings.clone(text, allocator)
	p.cut_topic = cut_topic
	p.flags = {.Text_Only}
	if !public {
		p.flags += {.Private}
	}
	if archived {
		p.flags += {.Archived}
	}
	if public && !archived {
		switch c.name {
		case HOME_CHANNEL:
			p.home = true
		case DEFAULT_CHANNEL:
			p.flags += {.Default}
		}
	}
	return
}

// topic_of returns what a channel's topic is: its header, or its purpose if it
// has no header.
topic_of :: proc(c: Channel) -> (topic: string, from_purpose: bool) {
	if strings.trim_space(c.header) != "" {
		return c.header, false
	}
	return c.purpose, strings.trim_space(c.purpose) != ""
}

// notify_of returns how a member wants to be notified of a channel's messages.
// The notification setting decides, and "default", which means whatever the
// member has set for everything, decides by whether the channel is marked as
// unread by every message or only by mentions.
notify_of :: proc(n: Notify_Props) -> proto.Notify_Level {
	switch n.desktop {
	case "none":
		return .None
	case "mention":
		return .Mentions
	case "all":
		return .All
	}
	return .Mentions if n.mark_unread == "mention" else .All
}

// has_role says whether a space separated list of roles has `role`.
has_role :: proc(roles, role: string) -> bool {
	list := roles
	for r in strings.split_iterator(&list, " ") {
		if r == role {
			return true
		}
	}
	return false
}

// is_channel_admin says whether a membership's roles make the member an admin
// of the channel.
is_channel_admin :: proc(roles: string) -> bool {
	return has_role(roles, "channel_admin")
}

// Account_Roles is what a user's roles come to in yap (D6).
Account_Roles :: struct {
	admin: bool, // the Admin role: a system admin, or an admin of the team
	guest: bool, // the guest role: can't see any channel until added to one
}

// roles_of returns the roles that a user has in `team`.
roles_of :: proc(u: User, team: string) -> (r: Account_Roles) {
	r.admin = has_role(u.roles, "system_admin")
	r.guest = has_role(u.roles, "system_guest")
	for t in u.teams {
		if t.name == team && has_role(t.roles, "team_admin") {
			r.admin = true
		}
	}
	return
}

// choose_owner returns the username of the account that becomes the server's
// owner: `requested`, or without one the first active system admin of the
// team's members. `err` says why there is none.
choose_owner :: proc(s: ^Scan, requested: string) -> (username: string, err: string) {
	if requested != "" {
		idx, found := s.user_index[requested]
		switch {
		case !found || !s.members[requested]:
			return "", "the owner has to be a member of the team, and there is no such user"
		case s.users[idx].delete_at != 0:
			return "", "the owner can't be a deactivated account, as it couldn't log in"
		}
		return requested, ""
	}
	for u in s.users {
		if s.members[u.username] && u.delete_at == 0 && has_role(u.roles, "system_admin") {
			return u.username, ""
		}
	}
	return "",
		"the export has no active system admin to make the owner; name an account with --owner"
}
