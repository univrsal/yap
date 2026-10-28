package mattermost

import "core:fmt"
import "core:io"
import "core:slice"
import "core:strings"
import "core:time"

// What a --dry-run prints, and what the real run prints first and keeps in
// import-report.txt: what an import of this export makes, what it leaves out
// and what is wrong with it.

// How an issue is worded in the report, and whether it only counts names
// (the first number then says how many different ones).
@(private = "file")
issue_text :: proc(kind: Issue_Kind) -> string {
	switch kind {
	case .Unknown_Line:
		return "lines of a type that isn't known, skipped"
	case .Duplicate_User:
		return "usernames that two accounts have; the later one is skipped"
	case .Author_Not_Member:
		return(
			"people who wrote in the team's channels but have left the team; they get an account that is disabled, and aren't in any channel" \
		)
	case .Author_Unknown:
		return(
			"authors that have no account in the export (deleted); their messages are kept under a deleted account" \
		)
	case .Post_Channel_Unknown:
		return "posts of the team in a channel the export doesn't have; skipped"
	case .Direct_Member_Gone:
		return(
			"direct channels with someone who isn't imported (not in the team, not a bot); left out" \
		)
	case .Direct_Channel_Unknown:
		return "direct posts in a channel that the export doesn't have; skipped"
	case .Reactions_Channel_Unknown:
		return "reactions in extras.jsonl to a post of a direct channel that isn't there; skipped"
	case .Attachment_Missing:
		return "attached files that aren't under data/; the messages are imported without them"
	case .Profile_Image_Missing:
		return "profile pictures that aren't under data/; those accounts get none"
	case .Emoji_Image_Missing:
		return "custom emoji whose picture isn't under data/; skipped"
	case .Username_Changed:
		return "usernames changed, as yap only takes a-z 0-9 _ . - or another account has the name"
	case .Email_Invalid:
		return "email addresses yap doesn't accept; those accounts get none"
	case .Email_Taken:
		return "email addresses that two accounts have (yap's are unique); the later one gets none"
	case .Channel_Renamed:
		return "channels renamed, as another channel has the same name; the archived ones first"
	case .Name_Cut:
		return "channel names cut to yap's limit"
	case .Topic_Cut:
		return "channel topics cut to yap's limit"
	case .Emoji_Renamed:
		return "custom emoji renamed, as yap's names are a-z 0-9 _ only, or another has the name"
	case .System_Dropped:
		return "kinds of system post that yap has no use for; left out"
	case .System_Unknown:
		return "kinds of system post this importer doesn't know; left out"
	case .Reaction_Tone:
		return "emoji with a skin tone, which yap has not; reactions use the emoji without it"
	case .Guest_Disabled:
		return(
			"guests, which yap has no kind of account for; their accounts are made disabled, for an admin to look at" \
		)
	case .Avatar_Failed:
		return "profile pictures that couldn't be read; those accounts get none"
	case .Reaction_Unknown:
		return "emoji names that aren't yap's or the server's own; those reactions are left out"
	}
	return ""
}

// format_time writes a Unix time in milliseconds as a date and time in UTC.
format_time :: proc(ms: i64, allocator := context.temp_allocator) -> string {
	t := time.unix(ms / 1000, 0)
	y, mon, d := time.date(t)
	h, m, _ := time.clock(t)
	return fmt.aprintf("%04d-%02d-%02d %02d:%02d", y, int(mon), d, h, m, allocator = allocator)
}

// report_write writes the report of a scan.
report_write :: proc(s: ^Scan, w: io.Writer) {
	st := s.stats
	fmt.wprintfln(w, "Mattermost export")
	fmt.wprintfln(
		w,
		"  made by %s, %s",
		s.info.version,
		s.info.created[:min(len(s.info.created), 16)],
	)
	fmt.wprintfln(
		w,
		"  %d lines in %s%s",
		s.lines,
		IMPORT_FILE,
		" and " + EXTRAS_FILE if s.has_extras else "",
	)

	// The teams.
	team_name := s.team
	for t in s.teams {
		if t.name == s.team {
			team_name = fmt.tprintf("%s (%s)", t.name, t.display_name)
		}
	}
	others := make([dynamic]string, 0, len(s.teams), context.temp_allocator)
	for t in s.teams {
		if t.name != s.team {
			append(&others, t.name)
		}
	}
	fmt.wprintfln(w, "\nTeam: %s", team_name)
	if len(others) > 0 {
		fmt.wprintfln(
			w,
			"  left out: %d other team(s): %s, with %d posts",
			len(others),
			strings.join(others[:], ", ", context.temp_allocator),
			st.posts_other_teams,
		)
	}

	// Accounts.
	active, deactivated, admins, sso, pictures: int
	for u in s.users {
		if !s.members[u.username] {
			continue
		}
		if u.delete_at != 0 {
			deactivated += 1
		} else {
			active += 1
		}
		if strings.contains(u.roles, "system_admin") {
			admins += 1
		}
		if u.auth_service != "" {
			sso += 1
		}
		if u.profile_image != "" {
			pictures += 1
		}
	}
	not_members := len(s.users) - len(s.members)
	fmt.wprintfln(w, "\nAccounts")
	fmt.wprintfln(
		w,
		"  %d from the team: %d active, %d deactivated; %d system admins, %d with a single sign-on login, %d with a profile picture",
		len(s.members),
		active,
		deactivated,
		admins,
		sso,
		pictures,
	)
	fmt.wprintfln(w, "  %d bots", len(s.bots))
	if not_members > 0 {
		fmt.wprintfln(
			w,
			"  %d other users in the export, not in the team (made only if they wrote in it, see below)",
			not_members,
		)
	}

	// Channels and direct channels.
	open, private, archived: int
	for c in s.channels {
		if c.type == "P" {
			private += 1
		} else {
			open += 1
		}
		if c.deleted_at != 0 {
			archived += 1
		}
	}
	dms, selfs, groups: int
	for d in s.directs {
		switch {
		case len(d.participants) >= 3:
			groups += 1
		case is_self(d):
			selfs += 1
		case:
			dms += 1
		}
	}
	fmt.wprintfln(w, "\nConversations")
	fmt.wprintfln(
		w,
		"  %d channels: %d open, %d private, %d archived",
		len(s.channels),
		open,
		private,
		archived,
	)
	fmt.wprintfln(
		w,
		"  %d direct: %d DMs, %d with oneself, %d group messages",
		len(s.directs),
		dms,
		selfs,
		groups,
	)
	if s.directs_left > 0 {
		fmt.wprintfln(
			w,
			"  left out: %d direct channels with someone who isn't imported, with %d posts",
			s.directs_left,
			st.direct_posts_left_out,
		)
	}

	// Messages.
	fmt.wprintfln(w, "\nMessages")
	fmt.wprintfln(
		w,
		"  %d in channels and %d in direct channels, of which %d replies in threads",
		st.posts,
		st.direct_posts,
		st.replies,
	)
	if st.first_time != 0 {
		fmt.wprintfln(
			w,
			"  from %s to %s (UTC)",
			format_time(st.first_time),
			format_time(st.last_time),
		)
	}
	fmt.wprintfln(
		w,
		"  %d system messages, %d pinned, %d edited, %d reactions, %d files attached, %d saved by someone",
		st.system,
		st.pinned,
		st.edited,
		st.reactions,
		st.attachments,
		st.saved,
	)
	if len(st.by_type) > 0 {
		types := make([dynamic]string, 0, len(st.by_type), context.temp_allocator)
		for name in st.by_type {
			append(&types, name)
		}
		slice.sort(types[:])
		fmt.wprintf(w, "  by type:")
		for name in types {
			fmt.wprintf(w, " %s %d,", name, st.by_type[name])
		}
		fmt.wprintln(w)
	}
	if len(s.emoji) > 0 {
		fmt.wprintfln(w, "\nCustom emoji: %d", len(s.emoji))
	}

	// What the mapping makes of it.
	if len(s.plan.accounts) > 0 {
		made, bots, left: int
		for acc in s.plan.accounts {
			switch {
			case acc.bot:
				bots += 1
			case acc.author_only:
				left += 1
			case:
				made += 1
			}
		}
		fmt.wprintfln(w, "\nAn import makes")
		fmt.wprintfln(
			w,
			"  %d accounts of the team's members, %d bots, %d disabled ones for people who left the team",
			made,
			bots,
			left,
		)
		fmt.wprintfln(w, "  the owner: %s", s.plan.owner)
		fmt.wprintfln(
			w,
			"  %d channels (the home channel is %s)",
			len(s.plan.channels),
			home_name(s),
		)
	}

	// What is wrong.
	any := false
	for kind in Issue_Kind {
		i := s.issues[kind]
		if i.count == 0 {
			continue
		}
		if !any {
			fmt.wprintfln(w, "\nWarnings")
			any = true
		}
		fmt.wprintfln(w, "  %d %s", i.count, issue_text(kind))
		for e in i.examples {
			fmt.wprintfln(w, "    %s", e)
		}
		if i.count > len(i.examples) {
			fmt.wprintfln(w, "    and %d more", i.count - len(i.examples))
		}
	}
	if !any {
		fmt.wprintfln(w, "\nNo warnings.")
	}
}

// is_self says whether a direct channel is a DM with oneself.
is_self :: proc(d: Direct_Channel) -> bool {
	if len(d.participants) == 0 {
		return false
	}
	for p in d.participants {
		if p.username != d.participants[0].username {
			return false
		}
	}
	return true
}

// home_name returns the name that the home channel gets.
@(private = "file")
home_name :: proc(s: ^Scan) -> string {
	for c in s.plan.channels {
		if c.home {
			return c.name
		}
	}
	return "not one of the team's"
}
