package server

import "core:fmt"
import "core:log"
import "core:mem/virtual"
import "core:slice"
import "core:strings"

import "common:proto"
import "mattermost"

// The importer's writing of conversations (docs/design/mattermost-import.md,
// 7d): the team's channels, who is in them and how they want to be told of
// them, and the DMs and groups. The accounts have to be made already
// (import_accounts). The channels have the names and topics that the plan
// gave them.

// import_channels makes the channels, their members, and the direct
// conversations. It writes in the open transaction and returns false, with a
// message logged, if anything fails.
import_channels :: proc(im: ^Importer) -> bool {
	s := im.scan
	plans := s.plan.channels
	c := im.convs
	im.channels = make([]^Conv, len(plans), virtual.arena_allocator(&im.arena))

	// The channels. The server made the home channel when it first looked at
	// the database; town-square becomes it, with its name and topic. Without a
	// town-square, it stays, and its name must not be another channel's.
	home := c.home
	home_planned := false
	for p, i in plans {
		if p.home {
			home_planned = true
			if !conv_update(c, home, p.name, p.topic, 0) ||
			   !conv_set_flags(c, home, p.flags + {.Home}) {
				log.errorf("could not make the home channel %s", p.name)
				return false
			}
			im.channels[i] = home
		}
	}
	if !home_planned {
		for p in plans {
			if strings.equal_fold(p.name, home.name) {
				name := fmt.tprintf("%s (home)", home.name)
				if !conv_update(c, home, name, home.topic, 0) {
					return false
				}
				break
			}
		}
	}
	// The others in alphabetical order, the archived ones last, so that the
	// list is in an order that means something. The home channel is first.
	keys := make([]string, len(plans), context.temp_allocator)
	order := make([dynamic]int, 0, len(plans), context.temp_allocator)
	for p, i in plans {
		prefix := "1" if .Archived in p.flags else "0"
		keys[i] = strings.concatenate(
			{prefix, strings.to_lower(p.name, context.temp_allocator)},
			context.temp_allocator,
		)
		if !p.home {
			append(&order, i)
		}
	}
	slice.sort_by_with_data(order[:], proc(a, b: int, data: rawptr) -> bool {
			keys := (^[]string)(data)^
			return keys[a] < keys[b]
		}, &keys)

	progress := progress_start("making channels")
	for i, position in order {
		p := plans[i]
		conv := conv_add(c, p.name, p.topic, p.flags, 0, position + 1)
		if conv == nil {
			log.errorf("could not make the channel %s", p.name)
			return false
		}
		im.channels[i] = conv
		progress_update(&progress, i64(position + 1), i64(len(order)))
	}
	progress.done = i64(len(order))
	progress_finish(&progress)

	import_members(im) or_return
	import_directs(im) or_return
	return true
}

// import_members puts every account in the channels it is in. Everybody is in
// the home channel, as the server has it; for the rest, a member of the team is
// where their memberships say. Bots and those who left the team are only in the
// home channel.
@(private = "file")
import_members :: proc(im: ^Importer) -> bool {
	s := im.scan
	c := im.convs
	total := 0
	for acc in s.plan.accounts {
		if !acc.bot && !acc.author_only {
			u := s.users[s.user_index[acc.mm_name]]
			for t in u.teams {
				total += len(t.channels)
			}
		}
	}
	for acc in s.plan.accounts {
		if !conv_member_add(c, c.home, im.ids[acc.mm_name]) {
			log.errorf("could not add %s to the home channel", acc.name)
			return false
		}
	}
	progress := progress_start("adding people to channels")
	done := 0
	for acc in s.plan.accounts {
		if acc.bot || acc.author_only {
			continue
		}
		id := im.ids[acc.mm_name]
		u := s.users[s.user_index[acc.mm_name]]
		for t in u.teams {
			for m in t.channels {
				done += 1
				progress_update(&progress, i64(done), i64(total))
				index, found := s.channel_index[m.name]
				if !found {
					continue
				}
				conv := im.channels[index]
				if !conv_member_add(c, conv, id) {
					log.errorf("could not add %s to %s", acc.name, conv.name)
					return false
				}
				notify := mattermost.notify_of(m.notify_props)
				if notify != .All && !conv_set_notify(c, conv, id, notify) {
					return false
				}
				if mattermost.is_channel_admin(m.roles) && !conv_set_admin(c, conv, id, true) {
					return false
				}
			}
		}
	}
	progress.done = i64(done)
	progress_finish(&progress)
	return true
}

// import_directs makes the DMs (one with oneself too) and groups.
@(private = "file")
import_directs :: proc(im: ^Importer) -> bool {
	s := im.scan
	c := im.convs
	im.direct_list = make([]^Conv, len(s.directs), virtual.arena_allocator(&im.arena))
	progress := progress_start("making direct conversations")
	for d, i in s.directs {
		progress_update(&progress, i64(i), i64(len(s.directs)))
		names := make([]string, len(d.participants), context.temp_allocator)
		ids := make([dynamic]proto.Account_Id, 0, len(d.participants), context.temp_allocator)
		for p, k in d.participants {
			names[k] = p.username
			id := im.ids[p.username]
			if !slice.contains(ids[:], id) {
				append(&ids, id)
			}
		}
		key := mattermost.direct_key(names)
		by := ids[0]
		conv: ^Conv
		switch {
		case len(ids) == 1:
			conv = dm_find(c, by, by)
			if conv == nil {
				conv = dm_add(c, by, by, by)
			}
		case len(ids) == 2:
			conv = dm_find(c, ids[0], ids[1])
			if conv == nil {
				conv = dm_add(c, ids[0], ids[1], by)
			}
		case:
			conv = group_find(c, ids[:])
			if conv == nil {
				conv = group_add(c, ids[:], by)
			}
		}
		if conv == nil {
			log.errorf("could not make the conversation of %s", key)
			return false
		}
		im.directs[strings.clone(key, virtual.arena_allocator(&im.arena))] = conv
		im.direct_list[i] = conv
		for p in d.participants {
			notify := mattermost.notify_of(p.notify_props)
			if notify != .All && !conv_set_notify(c, conv, im.ids[p.username], notify) {
				return false
			}
		}
	}
	progress.done = i64(len(s.directs))
	progress_finish(&progress)
	return true
}
