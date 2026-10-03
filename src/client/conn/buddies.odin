package conn

import log "common:wlog"
import "core:fmt"
import "core:slice"
import "core:time"

import "common:proto"

/*
Buddies, direct messages, and when people were last here
(src/common/proto/buddies.odin, and DMs in proto/convs.odin): what the
buddy screen is made of.

Our buddies are our account's, kept by the server: it tells us of them
when we log in and as they change, here or on another of our devices.

A DM is a conversation like a channel (convs.odin), with one other
account, and its messages are like any other's (messages.odin). We may
not have one with somebody yet: what we write to them waits in the
outbox while the server opens it (DM_Open), which it does once, for good.

When somebody was last here is asked for (Last_Seen_Command); the server
only says to people who have exchanged messages with them.
*/

Buddy_Client :: struct {
	buddies: [dynamic]proto.Account_Id,
}

// Add somebody as a buddy, or take them off: by account, or by name if
// the account is 0 (headless).
Buddy_Command :: struct {
	account: proto.Account_Id,
	name:    string, // owned by the command
	on:      bool,
}

// Ask when some accounts were last here; by name if there's none
// (headless).
Last_Seen_Command :: struct {
	accounts: [64]proto.Account_Id,
	count:    int,
	name:     string, // owned by the command
}

// List our buddies and DMs in the log (headless).
Buddies_Command :: struct {}

// Look at the DMs with somebody, and post `text` there if it isn't
// empty: by account, or by name if the account is 0 (headless).
DM_Command :: struct {
	account: proto.Account_Id,
	name:    string, // owned by the command
	text:    string, // owned by the command
}

buddies_destroy :: proc(c: ^Voice_Client) {
	delete(c.buddies.buddies)
	c.buddies = {}
}

// buddies_begin forgets our buddies: the server is about to tell us
// again, or we've been logged out.
buddies_begin :: proc(c: ^Voice_Client) {
	clear(&c.buddies.buddies)
	publish_buddies(c)
}

// buddies_event takes an event about buddies; false if `op` isn't one.
buddies_event :: proc(c: ^Voice_Client, op: proto.Event_Op, body: []u8) -> bool {
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
		log.infof("%s is %s", account_display(c, account), "a buddy now" if on else "no longer a buddy")
	}
	publish_buddies(c)
	return true
}

// account_named is the account somebody means by `name`: its username,
// or what it's called; 0 if there's none.
account_named :: proc(c: ^Voice_Client, name: string) -> proto.Account_Id {
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

// who is the account a command means: `account`, or the one called
// `name`. Not ourselves.
@(private = "file")
who :: proc(c: ^Voice_Client, account: proto.Account_Id, name: string) -> proto.Account_Id {
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

buddy_command :: proc(c: ^Voice_Client, cmd: Buddy_Command) {
	account := who(c, cmd.account, cmd.name)
	if account == 0 {
		return
	}
	buf: [proto.BUDDY_SET_SIZE]u8
	request(c, .Buddy_Set, proto.encode_buddy(&buf, account, cmd.on), proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
		if status != .Ok && status != .Reset {
			log.warnf("the server wouldn't change your buddies (%v)", status)
		}
	})
}

// is_online is whether an account has a connection here.
is_online :: proc(c: ^Voice_Client, account: proto.Account_Id) -> bool {
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

// dm_with is our DM conversation with an account, or 0 if there's none
// yet.
dm_with :: proc(c: ^Voice_Client, account: proto.Account_Id) -> proto.Conv_Id {
	for id, info in c.convs.convs {
		if info.kind == .DM && dm_other(c, info) == account {
			return id
		}
	}
	return 0
}

// dm_other is who a DM is with: of its two accounts, the one that isn't
// ours.
dm_other :: proc(c: ^Voice_Client, info: Conv_Info) -> proto.Account_Id {
	return info.b if info.a == c.auth.me else info.a
}

// dm_command looks at the DMs with somebody, posting to them first if
// there's text. Before there's a conversation there's nothing to look
// at: what's posted opens it.
dm_command :: proc(c: ^Voice_Client, cmd: DM_Command) {
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

last_seen_command :: proc(c: ^Voice_Client, cmd: Last_Seen_Command) {
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
	request(c, .Last_Seen, body, proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
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
		// Headless (/seen): the log is the only place to show it.
		for e in entries {
			name := account_display(c, e.account)
			switch e.time {
			case 0:
				log.infof("[seen] there's no account %d", e.account)
			case proto.LAST_SEEN_HIDDEN:
				log.infof("[seen] %s: not shared (you haven't both written to each other)", name)
			case:
				if is_online(c, e.account) {
					log.infof("[seen] %s: here now", name)
					break
				}
				ago := time.duration_seconds(time.since(time.unix(0, i64(e.time) * 1_000_000)))
				log.infof("[seen] %s: last here %.0f seconds ago", name, ago)
			}
		}
	})
}

// list_buddies logs our buddies and our DMs (headless /buddies).
list_buddies :: proc(c: ^Voice_Client) {
	for b in c.buddies.buddies {
		log.infof("buddy: %s%s", account_display(c, b), " (here)" if is_online(c, b) else "")
	}
	for id, info in c.convs.convs {
		if info.kind != .DM {
			continue
		}
		unread := ""
		if info.unread > 0 {
			unread = fmt.tprintf(", %s unread", unread_count(info.unread))
		}
		log.infof(
			"%s DMs with %s%s",
			"*" if id == c.convs.viewing else " ",
			account_display(c, dm_other(c, info)),
			unread,
		)
	}
	if len(c.buddies.buddies) == 0 && dm_count(c) == 0 {
		log.info("no buddies and no DMs yet")
	}
}

@(private = "file")
dm_count :: proc(c: ^Voice_Client) -> (n: int) {
	for _, info in c.convs.convs {
		if info.kind == .DM {
			n += 1
		}
	}
	return
}

publish_buddies :: proc(c: ^Voice_Client) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	clear(&v.buddies)
	append(&v.buddies, ..c.buddies.buddies[:])
}

publish_last_seen :: proc(c: ^Voice_Client, entries: []proto.Last_Seen_Entry) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	for e in entries {
		v.last_seen[e.account] = e.time
	}
}
