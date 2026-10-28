package conn

import log "common:wlog"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"

import "common:proto"

// This file handles buddies, direct messages and when people were last online
// (src/common/proto/buddies.odin, and DMs in proto/convs.odin). These make up
// the buddy screen.
//
// Our buddies belong to our account and are stored by the server. It sends
// them when we log in and whenever they change, whether the change was made
// here or on another of our devices.
//
// A DM is a conversation with exactly one other account. It works like a
// channel conversation (see convs.odin), and its messages are like any other
// messages (see messages.odin). We may not have a DM with somebody yet. In
// that case, what we write to them waits in the outbox until the server opens
// the DM (DM_Open), which it does only once per pair of accounts.
//
// A group is like a DM with 2 to proto.MAX_GROUP_MEMBERS - 1 others, which
// never change. It is opened with Group_Command (Group_Open) before anything is
// written there; until something is, the others don't see it.
//
// When somebody was last online is requested with Last_Seen_Command. The
// server only answers for people who have exchanged messages with us.

Buddy_Client :: struct {
	buddies: [dynamic]proto.Account_Id,
}

// Adds somebody as a buddy or removes them. The person is identified by
// account, or by name if the account is 0 (headless).
Buddy_Command :: struct {
	account: proto.Account_Id,
	name:    string, // owned by the command
	on:      bool,
}

// Asks when some accounts were last online. If no accounts are given, the
// name is used instead (headless).
Last_Seen_Command :: struct {
	accounts: [64]proto.Account_Id,
	count:    int,
	name:     string, // owned by the command
}

// Lists our buddies and DMs in the log (headless).
Buddies_Command :: struct {}

// Opens the DM with somebody and posts `text` there if it isn't empty. The
// person is identified by account, or by name if the account is 0 (headless).
DM_Command :: struct {
	account: proto.Account_Id,
	name:    string, // owned by the command
	text:    string, // owned by the command
}

// Opens the group of us and some others, creating it if there is none. The
// others are given as accounts, or as names separated by commas if there are no
// accounts (headless), and they must be 2 to proto.MAX_GROUP_MEMBERS - 1.
Group_Command :: struct {
	accounts: [proto.MAX_GROUP_MEMBERS - 1]proto.Account_Id,
	count:    int,
	names:    string, // owned by the command
}

buddies_destroy :: proc(c: ^Server_Conn) {
	delete(c.buddies.buddies)
	c.buddies = {}
}

// buddies_begin forgets our buddies, either because the server is about to send
// them again or because we've been logged out.
buddies_begin :: proc(c: ^Server_Conn) {
	clear(&c.buddies.buddies)
	publish_buddies(c)
}

// buddies_event handles an event about buddies. It returns false if `op` is not
// a buddy event.
buddies_event :: proc(c: ^Server_Conn, op: proto.Event_Op, body: []u8) -> bool {
	if op != .Buddy_Changed {
		return false
	}
	account, on, ok := proto.decode_buddy(body)
	if !ok {
		return true
	}
	b := &c.buddies
	i, has := slice.linear_search(b.buddies[:], account)
	switch {
	case on && !has:
		append(&b.buddies, account)
	case !on && has:
		ordered_remove(&b.buddies, i)
	case:
		return true
	}
	if c.convs.synced {
		log.infof(
			"%s is %s",
			account_display(c, account),
			"a buddy now" if on else "no longer a buddy",
		)
	}
	publish_buddies(c)
	return true
}

// account_named returns the account that `name` refers to, matching either the
// username or the display name. It returns 0 if there is no such account.
account_named :: proc(c: ^Server_Conn, name: string) -> proto.Account_Id {
	if id := account_by_username(c, name); id != 0 {
		return id
	}
	for id, acc in c.auth.accounts {
		if acc.display == name {
			return id
		}
	}
	return 0
}

// who returns the account a command refers to, which is `account` or else the
// account called `name`. It returns 0 if that is ourselves.
@(private = "file")
who :: proc(c: ^Server_Conn, account: proto.Account_Id, name: string) -> proto.Account_Id {
	id := account if account != 0 else account_named(c, name)
	switch {
	case id == 0:
		log.warnf("there's nobody called %q here", name)
	case id == c.auth.me:
		log.warn("that's you")
		return 0
	}
	return id
}

buddy_command :: proc(c: ^Server_Conn, cmd: Buddy_Command) {
	account := who(c, cmd.account, cmd.name)
	if account == 0 {
		return
	}
	buf: [proto.BUDDY_SET_SIZE]u8
	request(
		c,
		.Buddy_Set,
		proto.encode_buddy(&buf, account, cmd.on),
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			if status != .Ok && status != .Reset {
				log.warnf("the server failed to update your buddies (%v)", status)
			}
		},
	)
}

// is_online reports whether an account is connected to this server.
is_online :: proc(c: ^Server_Conn, account: proto.Account_Id) -> bool {
	if !c.channels.have_state {
		return false
	}
	for u in c.channels.state.users {
		if u.account == account {
			return true
		}
	}
	return false
}

// dm_with returns our DM conversation with an account, or 0 if there isn't one
// yet.
dm_with :: proc(c: ^Server_Conn, account: proto.Account_Id) -> proto.Conv_Id {
	for id, info in c.convs.convs {
		if info.kind == .DM && dm_other(c, info) == account {
			return id
		}
	}
	return 0
}

// dm_other returns the other participant of a DM, which is the one of its two
// accounts that isn't ours. It is 0 for anything else.
dm_other :: proc(c: ^Server_Conn, info: Conv_Info) -> proto.Account_Id {
	if info.kind != .DM {
		return 0
	}
	info := info
	for a in info.accounts[:clamp(info.account_count, 0, proto.MAX_GROUP_MEMBERS)] {
		if a != c.auth.me {
			return a
		}
	}
	return 0
}

// group_others returns the members of a group other than us, in ascending order,
// in the temp allocator. It is empty for anything but a group.
group_others :: proc(c: ^Server_Conn, info: Conv_Info) -> []proto.Account_Id {
	if info.kind != .Group {
		return nil
	}
	info := info
	others := make([dynamic]proto.Account_Id, 0, proto.MAX_GROUP_MEMBERS, context.temp_allocator)
	for a in info.accounts[:clamp(info.account_count, 0, proto.MAX_GROUP_MEMBERS)] {
		if a != c.auth.me {
			append(&others, a)
		}
	}
	return others[:]
}

// group_name returns what a group is called: the display names of its other
// members, joined with commas, in the temp allocator.
group_name :: proc(c: ^Server_Conn, info: Conv_Info) -> string {
	others := group_others(c, info)
	names := make([]string, len(others), context.temp_allocator)
	for a, i in others {
		names[i] = account_display(c, a)
	}
	return strings.join(names, ", ", context.temp_allocator)
}

// group_command opens a group (Group_Open), which the server tells us about
// (Conv_Changed) before it answers. Headless, the group is then looked at, so
// that /say posts there.
group_command :: proc(c: ^Server_Conn, cmd: Group_Command) {
	others := make([dynamic]proto.Account_Id, 0, len(cmd.accounts), context.temp_allocator)
	if cmd.count > 0 {
		cmd := cmd
		append(&others, ..cmd.accounts[:clamp(cmd.count, 0, len(cmd.accounts))])
	} else {
		for part in strings.split(cmd.names, ",", context.temp_allocator) {
			name := strings.trim_space(part)
			if name == "" {
				continue
			}
			account := who(c, 0, name)
			if account == 0 {
				return
			}
			if !slice.contains(others[:], account) {
				append(&others, account)
			}
		}
	}
	buf: [proto.GROUP_OPEN_MAX_SIZE]u8
	body := proto.encode_group_open(&buf, others[:])
	if body == nil {
		log.warnf(
			"a group is you and 2 to %d others; for one other, write a DM",
			proto.MAX_GROUP_MEMBERS - 1,
		)
		return
	}
	request(
		c,
		.Group_Open,
		body,
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			#partial switch status {
			case .Ok:
			case .Reset:
				return
			case .Denied:
				log.warn("bots can't be in a group")
				return
			case .Not_Found:
				log.warn("one of them isn't here any more")
				return
			case:
				log.warnf("the server failed to open the group (%v)", status)
				return
			}
			conv, ok := proto.decode_conv_id(body)
			if ok && c.view == nil && conv in c.convs.convs {
				conv_view(c, conv)
			}
		},
	)
}

// dm_command opens the DM with somebody, first posting `text` if there is any.
// If no conversation exists yet there is nothing to open, and posting the text
// is what creates it.
dm_command :: proc(c: ^Server_Conn, cmd: DM_Command) {
	account := who(c, cmd.account, cmd.name)
	if account == 0 {
		return
	}
	if cmd.text != "" {
		chat_send(c, typed_text(c, cmd.text), account)
	}
	if conv := dm_with(c, account); conv != 0 {
		conv_view(c, conv)
	} else if cmd.text == "" {
		log.infof("nothing has been said with %s yet", account_display(c, account))
	}
}

last_seen_command :: proc(c: ^Server_Conn, cmd: Last_Seen_Command) {
	cmd := cmd
	if cmd.count == 0 && cmd.name != "" {
		if account := who(c, 0, cmd.name); account != 0 {
			cmd.accounts[0], cmd.count = account, 1
		}
	}
	if cmd.count == 0 {
		return
	}
	buf: [2 + len(cmd.accounts) * 4]u8
	body := proto.encode_last_seen_ask(buf[:], cmd.accounts[:cmd.count])
	request(
		c,
		.Last_Seen,
		body,
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			if status != .Ok {
				return
			}
			buf: [64]proto.Last_Seen_Entry
			entries, ok := proto.decode_last_seen_answer(body, buf[:])
			if !ok {
				return
			}
			publish_last_seen(c, entries)
			if c.view != nil {
				return
			}
			// Headless (/seen): the log is the only place to show the result.
			for e in entries {
				name := account_display(c, e.account)
				switch e.time {
				case 0:
					log.infof("[seen] there's no account %d", e.account)
				case proto.LAST_SEEN_HIDDEN:
					log.infof(
						"[seen] %s: not shared (you haven't both written to each other)",
						name,
					)
				case:
					if is_online(c, e.account) {
						log.infof("[seen] %s: here now", name)
						break
					}
					ago := time.duration_seconds(time.since(time.unix(0, i64(e.time) * 1_000_000)))
					log.infof("[seen] %s: last here %.0f seconds ago", name, ago)
				}
			}
		},
	)
}

// list_buddies logs our buddies and DMs (headless /buddies).
list_buddies :: proc(c: ^Server_Conn) {
	for b in c.buddies.buddies {
		log.infof("buddy: %s%s", account_display(c, b), " (here)" if is_online(c, b) else "")
	}
	for id, info in c.convs.convs {
		if info.kind == .Channel {
			continue
		}
		unread := ""
		if info.unread > 0 {
			unread = fmt.tprintf(", %s unread", unread_count(info.unread))
		}
		log.infof(
			"%s %s%s",
			"*" if id == c.convs.viewing else " ",
			room_name(c, proto.Room(id)),
			unread,
		)
	}
	if len(c.buddies.buddies) == 0 && dm_count(c) == 0 {
		log.info("no buddies and no DMs yet")
	}
}

@(private = "file")
dm_count :: proc(c: ^Server_Conn) -> (n: int) {
	for _, info in c.convs.convs {
		if info.kind != .Channel {
			n += 1
		}
	}
	return
}

publish_buddies :: proc(c: ^Server_Conn) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	clear(&v.buddies)
	append(&v.buddies, ..c.buddies.buddies[:])
}

publish_last_seen :: proc(c: ^Server_Conn, entries: []proto.Last_Seen_Entry) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	for e in entries {
		v.last_seen[e.account] = e.time
	}
}
