package conn

import "core:fmt"
import "core:strings"

import "common:proto"

// Small questions about a View that any front end asks the same way. They were
// the window client's own (ui_channels.odin, ui_timeline.odin) before the
// terminal client needed them too.

// viewed_channel is the channel whose chat is showing, or nil. Call
// with the View locked.
viewed_channel :: proc(v: ^View) -> ^View_Channel {
	for &ch in v.channels {
		if ch.id == v.viewing {
			return &ch
		}
	}
	return nil
}

// viewed_unread is what is unread in the conversation being looked at, up to
// where it has been read, and how many of the unread messages mention us. Call
// with the View locked.
viewed_unread :: proc(v: ^View) -> (unread: int, read: proto.Msg_Id, mentions: int) {
	if ch := viewed_channel(v); ch != nil {
		return ch.unread, ch.read, ch.mentions
	}
	for dm in v.dms {
		if dm.id == v.viewing {
			return dm.unread, dm.read, dm.mentions
		}
	}
	return
}

// system_line is what a system message says: a call's line, with a phone in
// front of it if it counts as unread. In the temp allocator. Call with the
// View locked.
system_line :: proc(v: ^View, m: View_Message) -> string {
	name_of :: proc(v: ^View, id: proto.Account_Id) -> string {
		if acc, ok := v.accounts[id]; ok {
			return acc.display
		}
		return "someone"
	}
	text := system_text(
		m.system,
		m.system_arg,
		m.text,
		name_of(v, m.sender),
		name_of(v, proto.Account_Id(m.system_arg)),
		m.sender == v.me,
	)
	if proto.system_counts_unread(m.system) {
		return fmt.tprintf("\U0001F4DE %s", text)
	}
	return text
}

// dm_name is how a DM or a group is named: the other person's name, or the
// names of the others in a group, joined with commas. The name is in the temp
// allocator. Call with the View locked.
dm_name :: proc(v: ^View, dm: ^View_DM) -> string {
	others := group_members(dm)
	if len(others) == 0 {
		others = {dm.with}
	}
	names := make([]string, len(others), context.temp_allocator)
	for id, i in others {
		names[i] = "someone"
		if acc, ok := v.accounts[id]; ok {
			names[i] = acc.display
		}
	}
	return strings.join(names, ", ", context.temp_allocator)
}

// dm_closed is whether a DM or a group can't be written to any more: a DM with
// someone whose account was deleted, or a group in which nobody else's
// account is left (the server refuses it too). Call with the View locked.
dm_closed :: proc(v: ^View, dm: ^View_DM) -> bool {
	others := group_members(dm)
	if len(others) == 0 {
		others = {dm.with}
	}
	for id in others {
		if acc, ok := v.accounts[id]; !ok || .Deleted not_in acc.flags {
			return false
		}
	}
	return true
}
