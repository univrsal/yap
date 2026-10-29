package mattermost

import "core:fmt"
import "core:mem/virtual"
import "core:slice"
import "core:strings"

import "common:proto"


// The plan: what the scan found, with the mapping rules applied to all of it.
// The accounts and channels that an import makes, with the names they get, and
// what had to be changed on the way, as issues in the Scan. The writing steps
// of the importer (7c onwards) take their names and values from here, so that
// what the report says is what is done.

// Account_Plan is an account that the import makes.
Account_Plan :: struct {
	mm_name:     string, // the username in Mattermost
	name:        string, // the username in yap, unique
	display:     string,
	email:       string, // "" for none
	owner:       bool,
	admin:       bool, // gets the Admin role
	guest:       bool, // gets the guest role
	bot:         bool,
	webhook:     bool, // a bot made for a webhook, which has no account in Mattermost
	disabled:    bool, // deactivated in Mattermost, or has left the team
	author_only: bool, // not a member of the team: wrote in it, and is in no channel
}

Plan :: struct {
	owner:    string, // the owner's username in yap
	accounts: [dynamic]Account_Plan, // members, then bots, then those who left
	by_name:  map[string]int, // Mattermost username -> index in `accounts`
	channels: []Channel_Plan, // as Scan.channels
	emoji:    Emoji_Map, // yap's, and the custom ones under their names in yap
	// The custom emoji that are made: each is an index in Scan.emoji, with the
	// name it gets (unique, valid) and the file it is put in the folder as.
	made:     [dynamic]Emoji_Plan,
}

Emoji_Plan :: struct {
	index:   int,
	name:    string,
	ext:     string,
	convert: bool,
}

// The start of the name that a webhook's bot has in the plan (Account_Plan.mm_name).
WEBHOOK_PREFIX :: "webhook:"

// build_plan applies the mapping rules to a scan. `owner` is the account that
// was asked for as the owner, or "". If there can be none, `err` says why.
build_plan :: proc(s: ^Scan, owner: string) -> (err: string) {
	a := virtual.arena_allocator(&s.arena)
	p := &s.plan
	p.accounts.allocator = a
	p.by_name = make(map[string]int, a)

	chosen, msg := choose_owner(s, owner)
	if msg != "" {
		return strings.clone(msg)
	}
	p.owner = chosen

	// Accounts: one namespace for people and bots.
	names := unique_make(.Underscore, a)
	emails := make(map[string]bool, a)
	add :: proc(
		s: ^Scan,
		p: ^Plan,
		names: ^Unique,
		emails: ^map[string]bool,
		acc: Account_Plan,
		raw_email: string,
		a: Allocator,
	) {
		acc := acc
		changed: bool
		acc.name, changed = username_of(names, acc.mm_name)
		if changed {
			note(s, .Username_Changed, fmt.tprintf("%s -> %s", acc.mm_name, acc.name), a)
		}
		problem: Email_Problem
		acc.email, problem = email_of(emails, raw_email, a)
		switch problem {
		case .None:
		case .Invalid:
			note(s, .Email_Invalid, fmt.tprintf("%s: %s", acc.name, raw_email), a)
		case .Taken:
			note(s, .Email_Taken, fmt.tprintf("%s: %s", acc.name, raw_email), a)
		}
		p.by_name[acc.mm_name] = len(p.accounts)
		append(&p.accounts, acc)
	}
	for u in s.users {
		if !s.members[u.username] {
			continue
		}
		roles := roles_of(u, s.team)
		// yap has no kind of account that sees only the channels it was added
		// to, so a guest would see every public channel. It is made disabled,
		// for an admin to look at.
		if roles.guest {
			note(s, .Guest_Disabled, u.username, a)
		}
		add(
			s,
			p,
			&names,
			&emails,
			{
				mm_name = strings.clone(u.username, a),
				display = strings.clone(display_of(u), a),
				owner = u.username == chosen,
				admin = roles.admin,
				guest = roles.guest,
				disabled = u.delete_at != 0 || roles.guest,
			},
			u.email,
			a,
		)
	}
	for b in s.bots {
		add(
			s,
			p,
			&names,
			&emails,
			{
				mm_name = strings.clone(b.username, a),
				display = strings.clone(bot_display_of(b), a),
				bot = true,
				disabled = b.delete_at != 0,
			},
			"",
			a,
		)
	}
	for name in s.authors_only {
		u := s.users[s.user_index[name]]
		add(
			s,
			p,
			&names,
			&emails,
			{
				mm_name = name,
				display = strings.clone(display_of(u), a),
				disabled = true,
				author_only = true,
			},
			u.email,
			a,
		)
	}

	// A bot for each webhook that posted in a channel (D13). It has no account in
	// Mattermost, so its name there is the hook's, behind "webhook:", which isn't
	// a username.
	for hook in s.webhooks {
		display, _ := clean_text(hook, proto.MAX_NAME_SIZE)
		if display == "" {
			display = "webhook"
		}
		username, _ := username_of(&names, hook)
		mm_name := strings.concatenate({WEBHOOK_PREFIX, hook}, a)
		p.by_name[mm_name] = len(p.accounts)
		append(
			&p.accounts,
			Account_Plan {
				mm_name = mm_name,
				name = username,
				display = strings.clone(display, a),
				bot = true,
				webhook = true,
			},
		)
	}

	// The owner, under the name it has in yap.
	p.owner = p.accounts[p.by_name[chosen]].name

	// Channels.
	p.channels = plan_channels(s.channels[:], a)
	for c, i in p.channels {
		if s.channels[i].scheme != "" {
			note(
				s,
				.Channel_Scheme,
				fmt.tprintf("%s: %s", s.channels[i].name, s.channels[i].scheme),
				a,
			)
		}
		if c.renamed {
			note(
				s,
				.Channel_Renamed,
				fmt.tprintf("%s -> %s", s.channels[i].display_name, c.name),
				a,
			)
		}
		if c.cut_name {
			note(s, .Name_Cut, s.channels[i].name, a)
		}
		if c.cut_topic {
			note(s, .Topic_Cut, s.channels[i].name, a)
		}
	}

	// Emoji and reactions.
	p.emoji = emoji_map_make(a)
	emoji_names := unique_make(.Underscore, a)
	p.made.allocator = a
	// A server has at most MAX_CUSTOM_EMOJI of its own (D18): the ones that are
	// used most are kept, by reactions and by the times it is written in a
	// message, and then by name.
	candidates := make([dynamic]int, 0, len(s.emoji), context.temp_allocator)
	for _, i in s.emoji {
		if i < len(s.emoji_files) && s.emoji_files[i].ok {
			append(&candidates, i)
		}
	}
	kept := make(map[int]bool, context.temp_allocator)
	if len(candidates) <= proto.MAX_CUSTOM_EMOJI {
		for i in candidates {
			kept[i] = true
		}
	} else {
		usage :: proc(s: ^Scan, i: int) -> int {
			name := s.emoji[i].name
			return s.stats.reaction_names[name] + s.stats.text_tokens[name]
		}
		ranked := slice.clone(candidates[:], context.temp_allocator)
		slice.sort_by_with_data(ranked, proc(x, y: int, data: rawptr) -> bool {
				s := (^Scan)(data)
				ux, uy := usage(s, x), usage(s, y)
				if ux != uy {
					return ux > uy
				}
				return s.emoji[x].name < s.emoji[y].name
			}, s)
		for i, rank in ranked {
			if rank < proto.MAX_CUSTOM_EMOJI {
				kept[i] = true
			} else {
				note(s, .Emoji_Over_Limit, fmt.tprintf("%s (%d)", s.emoji[i].name, usage(s, i)), a)
			}
		}
	}
	for e, i in s.emoji {
		if !kept[i] {
			continue
		}
		name, changed := custom_emoji_name(&emoji_names, e.name)
		if changed {
			note(s, .Emoji_Renamed, fmt.tprintf("%s -> %s", e.name, name), a)
		}
		emoji_add_custom(&p.emoji, e.name, name)
		append(&p.made, Emoji_Plan{i, name, s.emoji_files[i].ext, s.emoji_files[i].convert})
	}
	for name, count in s.stats.reaction_names {
		_, result := map_reaction(&p.emoji, name, context.temp_allocator)
		switch result {
		case .Mapped:
		case .Tone_Dropped:
			note(s, .Reaction_Tone, fmt.tprintf("%s (%d)", name, count), a)
		case .Unknown:
			note(s, .Reaction_Unknown, fmt.tprintf("%s (%d)", name, count), a)
		}
	}

	// System posts that are left out or not known, by type.
	for type, count in s.stats.by_type {
		_, result := map_system(type, "", nil, false, context.temp_allocator)
		#partial switch result {
		case .Dropped:
			note(s, .System_Dropped, fmt.tprintf("%s (%d)", type, count), a)
		case .Unknown:
			note(s, .System_Unknown, fmt.tprintf("%s (%d)", type, count), a)
		}
	}
	return ""
}
