package conn

import log "common:wlog"
import "core:fmt"
import "core:strconv"
import "core:strings"

import "common:proto"

// Administering a channel: its name and topic, its rights, its flags, its members,
// and deleting it.

// Change a channel (0: the one we're looking at) as selected by the mask.
Conv_Update_Command :: struct {
	conv:     proto.Conv_Id,
	mask:     u8,
	name:     string, // owned by the command
	topic:    string, // owned by the command
	position: int,
	flags:    proto.Conv_Flags, // with proto.CONV_UPDATE_FLAGS: Default, Text_Only
}

// Fetches a channel's rights map (View.rights_map), for those who manage
// channels.
Conv_Rights_Get_Command :: struct {
	conv: proto.Conv_Id,
}

// Replaces a channel's rights map.
Conv_Rights_Set_Command :: struct {
	conv:    proto.Conv_Id,
	entries: []proto.Role_Rights, // owned by the command
}

// Headless: turns one of a channel's flags (Default or Text_Only) on or off,
// keeping the other.
Conv_Flag_Command :: struct {
	conv: proto.Conv_Id, // 0: the one we're looking at
	flag: proto.Conv_Flag,
	on:   bool,
}

// Headless: replaces a channel's rights map with one given as text, such as
// "everyone=see,react writers=see,write,edit,delete" (see conv_rights_parse).
Conv_Rights_Text_Command :: struct {
	conv: proto.Conv_Id, // 0: the one we're looking at
	text: string, // owned by the command
}

Conv_Delete_Command :: struct {
	conv: proto.Conv_Id,
}

// Add somebody to a channel (0: the one we're looking at), or remove them from
// a private one. Headless, by name.
Conv_Member_Command :: struct {
	conv:    proto.Conv_Id,
	account: proto.Account_Id,
	name:    string, // owned by the command
	on:      bool,
}

conv_update :: proc(c: ^Server_Conn, cmd: Conv_Update_Command) {
	conv := cmd.conv if cmd.conv != 0 else c.convs.viewing
	buf: [proto.CONV_UPDATE_MAX_SIZE]u8
	body := proto.encode_conv_update(
		buf[:],
		{
			conv = conv,
			mask = cmd.mask,
			name = cmd.name,
			topic = cmd.topic,
			position = cmd.position,
			flags = cmd.flags,
		},
	)
	if body == nil {
		notify(c, false, "The channel name or topic is too long.")
		return
	}
	c.convs.changing += 1
	request(c, .Conv_Update, body, conv_done)
}

// A channel's rights map, as the channel settings show it.
View_Rights_Map :: struct {
	conv:    proto.Conv_Id,
	entries: [dynamic]proto.Role_Rights,
	loading: bool,
	count:   int, // incremented whenever it arrives
}

// conv_rights_fetch asks for a channel's rights map, for the UI (or for the
// log when headless).
conv_rights_fetch :: proc(c: ^Server_Conn, conv: proto.Conv_Id) {
	if conv == 0 {
		return
	}
	publish_rights_map(c, conv, nil, true)
	buf: [4]u8
	request(
		c,
		.Conv_Rights_Get,
		proto.encode_conv_id(&buf, conv),
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			conv := proto.Conv_Id(tag)
			buf: [proto.MAX_ROLES]proto.Role_Rights
			entries, ok := proto.decode_rights_map(body, buf[:])
			if status != .Ok || !ok {
				publish_rights_map(c, conv, nil, false)
				if status != .Reset {
					manage_done(c, status if status != .Ok else .Invalid, nil, 0)
				}
				return
			}
			publish_rights_map(c, conv, entries, false)
			report_rights(c, entries)
		},
		u64(conv),
	)
}

conv_rights_set :: proc(c: ^Server_Conn, cmd: Conv_Rights_Set_Command) {
	conv := cmd.conv if cmd.conv != 0 else c.convs.viewing
	buf: [proto.CONV_RIGHTS_SET_MAX_SIZE]u8
	body := proto.encode_conv_rights_set(buf[:], conv, cmd.entries)
	if body == nil {
		notify(c, false, "There are too many roles in that.")
		return
	}
	request(
		c,
		.Conv_Rights_Set,
		body,
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			manage_done(c, status, body, tag)
			if status == .Ok && c.view != nil && c.view.rights_map.conv == proto.Conv_Id(tag) {
				conv_rights_fetch(c, proto.Conv_Id(tag))
			}
		},
		u64(conv),
	)
}

conv_flag_set :: proc(c: ^Server_Conn, cmd: Conv_Flag_Command) {
	conv := cmd.conv if cmd.conv != 0 else c.convs.viewing
	info, ok := c.convs.convs[conv]
	if !ok {
		log.warn("that's not one of our channels")
		return
	}
	flags := info.flags & proto.CONV_SETTABLE_FLAGS
	if cmd.on {
		flags += {cmd.flag}
	} else {
		flags -= {cmd.flag}
	}
	conv_update(c, {conv = conv, mask = proto.CONV_UPDATE_FLAGS, flags = flags})
}

// conv_rights_parse reads a rights map written as words of role=rights, the
// rights separated by commas ("none" for none), such as
// "everyone=see,react writers=see,write". A role may be named by its name or
// its number. It returns false, having logged why, if something isn't known.
conv_rights_parse :: proc(
	c: ^Server_Conn,
	text: string,
	buf: []proto.Role_Rights,
) -> (
	entries: []proto.Role_Rights,
	ok: bool,
) {
	count := 0
	for word in strings.fields(text, context.temp_allocator) {
		name, _, list := strings.partition(word, "=")
		role := role_named(c, name)
		if role == 0 {
			if n, is_number := strconv.parse_int(name);
			   is_number && proto.Role_Id(n) in c.auth.roles {
				role = proto.Role_Id(n)
			}
		}
		if role == 0 {
			log.warnf("there's no role called %q", name)
			return
		}
		rights: proto.Conv_Rights
		for r in strings.split(list, ",", context.temp_allocator) {
			found := r == "none" || r == ""
			for right in proto.Conv_Right {
				if strings.equal_fold(r, fmt.tprint(right)) {
					rights += {right}
					found = true
				}
			}
			if !found {
				log.warnf(
					"there's no right called %q (see, write, attach, react, edit, delete, voice)",
					r,
				)
				return
			}
		}
		if count == len(buf) {
			log.warn("that's too many roles")
			return
		}
		buf[count] = {role, rights}
		count += 1
	}
	return buf[:count], true
}

conv_rights_text_set :: proc(c: ^Server_Conn, cmd: Conv_Rights_Text_Command) {
	conv := cmd.conv if cmd.conv != 0 else c.convs.viewing
	buf: [proto.MAX_ROLES]proto.Role_Rights
	if entries, ok := conv_rights_parse(c, cmd.text, buf[:]); ok {
		conv_rights_set(c, {conv = conv, entries = entries})
	}
}

// rights_text names rights for people: "see, write, react", or "none".
rights_text :: proc(rights: proto.Conv_Rights) -> string {
	if rights == {} {
		return "none"
	}
	names := make([dynamic]string, context.temp_allocator)
	for r in proto.Conv_Right {
		if r in rights {
			append(&names, strings.to_lower(fmt.tprint(r), context.temp_allocator))
		}
	}
	return strings.join(names[:], ", ", context.temp_allocator)
}

@(private = "file")
publish_rights_map :: proc(
	c: ^Server_Conn,
	conv: proto.Conv_Id,
	entries: []proto.Role_Rights,
	loading: bool,
) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	clear(&v.rights_map.entries)
	v.rights_map.conv = conv
	append(&v.rights_map.entries, ..entries)
	v.rights_map.loading = loading
	v.rights_map.count += 1
}

conv_delete :: proc(c: ^Server_Conn, conv: proto.Conv_Id) {
	buf: [4]u8
	c.convs.changing += 1
	request(
		c,
		.Conv_Delete,
		proto.encode_conv_id(&buf, conv if conv != 0 else c.convs.viewing),
		conv_done,
	)
}

// conv_done is manage_done for a change to a channel, which may change the
// lists of channels (channels_changed). Moving a channel is several changes at
// once, so that waits for the last one.
@(private = "file")
conv_done :: proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
	manage_done(c, status, body, tag)
	c.convs.changing = max(c.convs.changing - 1, 0)
	if c.convs.changing == 0 && status != .Reset {
		channels_changed(c)
	}
}

conv_member_set :: proc(c: ^Server_Conn, cmd: Conv_Member_Command) {
	conv := cmd.conv if cmd.conv != 0 else c.convs.viewing
	account := cmd.account if cmd.account != 0 else account_named(c, cmd.name)
	if account == 0 {
		log.warn("there's no such account")
		return
	}
	buf: [proto.CONV_MEMBER_SET_SIZE]u8
	c.convs.changing += 1
	request(
		c,
		.Conv_Member_Set,
		proto.encode_conv_member_set(&buf, conv, account, cmd.on),
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			conv_done(c, status, body, tag)
			// Fetch the members shown again.
			if status == .Ok && c.profiles.members_conv != 0 {
				members_fetch(c, c.profiles.members_conv)
			}
		},
	)
}
