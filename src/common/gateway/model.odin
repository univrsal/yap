package gateway

import "core:fmt"
import "core:reflect"
import "core:slice"
import "core:strings"
import "core:time"

import "common:proto"

/*
What the gateway keeps of each connection (docs/bot-api, "What the
gateway keeps"): the protocol tells a client everything when it logs in
and then only what changes, and has no request for most of it, so GETs
are answered from here. Rebuilt from every Sync_Begin..Sync_End.

Who the connection is (Self), the roles, the accounts, the conversations
its account is in with what it has read of each, and who is online
(the snapshots). A conversation's newest message and what's unread
follow the messages as they come, as a client counts them; mentions
since the last Read_Changed aren't counted (that takes knowing who a
mention is of, which the server says when it says what's read).
*/

Model :: struct {
	self:        proto.Account_Id, // 0 until Self
	permissions: proto.Permissions,
	flags:       proto.Account_Flags,
	roles:       map[proto.Role_Id]Role_Record,
	accounts:    map[proto.Account_Id]Account_Record,
	convs:       map[proto.Conv_Id]Conv_Record,
	// How many connections each account has here (not those who appear
	// offline, whom the server leaves out).
	online:      map[proto.Account_Id]int,
	// What the server says about itself, asked once and then kept up
	// with Server_Info events; its strings owned.
	server:      proto.Server_Info,
	server_known: bool,
}

// Records as the model keeps them: their strings (and roles) owned.
Account_Record :: struct {
	using account: proto.Account,
}

Role_Record :: struct {
	using role: proto.Role,
}

Conv_Record :: struct {
	using conv: proto.Conv,
}

model_destroy :: proc(m: ^Model) {
	model_clear(m)
	server_free(&m.server)
	delete(m.roles)
	delete(m.accounts)
	delete(m.convs)
	delete(m.online)
	m^ = {}
}

// model_clear forgets what a sync tells again; who is online comes with
// the snapshots, which go on.
@(private)
model_clear :: proc(m: ^Model) {
	for _, &a in m.accounts {
		account_free(&a)
	}
	for _, &r in m.roles {
		delete(r.name)
	}
	for _, &c in m.convs {
		conv_free(&c)
	}
	clear(&m.accounts)
	clear(&m.roles)
	clear(&m.convs)
}

model_event :: proc(m: ^Model, op: proto.Event_Op, body: []u8) {
	#partial switch op {
	case .Sync_Begin:
		// How things are comes next, all of it.
		model_clear(m)
	case .Self:
		if id, permissions, flags, ok := proto.decode_self(body); ok {
			m.self, m.permissions, m.flags = id, permissions, flags
		}
	case .Account_Changed:
		a, ok := proto.decode_account(body)
		if !ok {
			return
		}
		if old, had := &m.accounts[a.id]; had {
			account_free(old)
		}
		a.username = strings.clone(a.username)
		a.display = strings.clone(a.display)
		a.status = strings.clone(a.status)
		a.roles = slice.clone(a.roles)
		m.accounts[a.id] = {a}
	case .Role_Changed:
		r, ok := proto.decode_role(body)
		if !ok {
			return
		}
		if old, had := &m.roles[r.id]; had {
			delete(old.name)
		}
		r.name = strings.clone(r.name)
		m.roles[r.id] = {r}
	case .Role_Removed:
		id, ok := proto.decode_conv_id(body) // a u32, as a conversation's is
		if !ok {
			return
		}
		if old, had := &m.roles[proto.Role_Id(id)]; had {
			delete(old.name)
			delete_key(&m.roles, proto.Role_Id(id))
		}
	case .Conv_Changed:
		c, ok := proto.decode_conv(body)
		if !ok {
			return
		}
		if old, had := &m.convs[c.id]; had {
			conv_free(old)
		}
		c.name = strings.clone(c.name)
		c.topic = strings.clone(c.topic)
		m.convs[c.id] = {c}
	case .Conv_Removed:
		id, ok := proto.decode_conv_id(body)
		if !ok {
			return
		}
		if old, had := &m.convs[id]; had {
			conv_free(old)
			delete_key(&m.convs, id)
		}
	case .Read_Changed:
		s, ok := proto.decode_read_changed(body)
		if !ok {
			return
		}
		if c, had := &m.convs[s.conv]; had {
			c.read, c.unread, c.mentions = s.read, s.unread, s.mentions
		}
	case .Server_Info:
		model_server(m, body)
	case .Msg_New:
		msg, ok := proto.decode_message(body)
		if !ok {
			return
		}
		c, had := &m.convs[msg.conv]
		if !had || msg.id <= c.last {
			return
		}
		c.last, c.last_time = msg.id, msg.time
		switch {
		case msg.sender == m.self:
			// Posting reads everything up to the post.
			c.read, c.unread, c.mentions = msg.id, 0, 0
		case msg.id > c.read:
			c.unread = min(c.unread + 1, proto.UNREAD_CAP)
		}
	}
}

// model_server takes what the server says about itself.
model_server :: proc(m: ^Model, body: []u8) {
	info, ok := proto.decode_server_info(body)
	if !ok {
		return
	}
	server_free(&m.server)
	info.name = strings.clone(info.name)
	info.version = strings.clone(info.version)
	info.email = strings.clone(info.email)
	info.description = strings.clone(info.description)
	m.server, m.server_known = info, true
}

@(private)
server_free :: proc(s: ^proto.Server_Info) {
	delete(s.name)
	delete(s.version)
	delete(s.email)
	delete(s.description)
	s^ = {}
}

// model_state takes a snapshot of who is here.
model_state :: proc(m: ^Model, state: proto.Presence) {
	clear(&m.online)
	for u in state.users {
		m.online[u.account] += 1
	}
}

@(private)
account_free :: proc(a: ^Account_Record) {
	delete(a.username)
	delete(a.display)
	delete(a.status)
	delete(a.roles)
}

@(private)
conv_free :: proc(c: ^Conv_Record) {
	delete(c.name)
	delete(c.topic)
}

// account_name is a connection's account, for the log.
account_name :: proc(c: ^Conn) -> string {
	if a, ok := c.model.accounts[c.model.self]; ok {
		return a.username
	}
	return fmt.tprintf("account %d", c.model.self)
}

/*
JSON (docs/bot-api, "Messages as JSON"): ids as strings, times as ISO
8601 in UTC, absent things as null, Discord's names where the thing is
the same. What's made here is in the temp allocator.
*/

Account_JSON :: struct {
	id:           string,
	username:     string,
	display:      string,
	bot:          bool,
	deleted:      bool,
	status:       Maybe(string),
	status_until: Maybe(string),
	avatar:       Maybe(string), // a blob id
	activity:     string, // online, away, busy, offline: as they set it
	online:       bool, // connected now, and not appearing offline
	roles:        []string,
}

// What /me says: the account, and what it may do.
Me_JSON :: struct {
	id:           string,
	username:     string,
	display:      string,
	bot:          bool,
	owner:        bool,
	status:       Maybe(string),
	status_until: Maybe(string),
	avatar:       Maybe(string),
	activity:     string,
	roles:        []string,
	permissions:  []string, // beyond everyone's: manage_messages, ...
}

Role_JSON :: struct {
	id:          string,
	name:        string,
	color:       Maybe(string), // "#rrggbb"
	position:    int, // lower is higher up
	permissions: []string,
	mentionable: bool,
	everyone:    bool, // the role every account has
}

Conv_JSON :: struct {
	id:                     string,
	kind:                   string, // channel, dm
	name:                   string,
	topic:                  string,
	home:                   bool, // the channel everyone is in
	private:                bool,
	position:               int,
	// A DM's other account.
	recipient:              Maybe(string),
	member:                 bool,
	last_message_id:        Maybe(string),
	last_message_timestamp: Maybe(string),
	// What the account has read, as a member.
	last_read_id:           Maybe(string),
	unread:                 int,
	mentions:               int,
	notify:                 string, // all, mentions, none
}

Author_JSON :: struct {
	id:       string,
	username: string,
	display:  string,
	bot:      bool,
}

Attachment_JSON :: struct {
	id:   Maybe(string), // the file's blob; null once it's been removed
	name: string,
	size: u64,
}

Reaction_JSON :: struct {
	emoji: string, // the character, or :name: of the server's own
	count: int,
	me:    bool,
}

Forwarded_JSON :: struct {
	author_id: string,
	conv_id:   string,
	timestamp: string,
}

Replies_JSON :: struct {
	count:   int,
	last_id: string,
}

File_JSON :: struct {
	name: string,
	size: u64,
}

System_JSON :: struct {
	what: int,
	arg:  int,
}

Message_JSON :: struct {
	id:               string,
	conv_id:          string,
	author:           Author_JSON,
	timestamp:        string,
	edited_timestamp: Maybe(string),
	kind:             string, // text, file, system
	content:          string,
	thread:           Maybe(string), // the thread's first message, if it's in one
	attachments:      []Attachment_JSON,
	reactions:        []Reaction_JSON,
	pinned:           bool,
	deleted:          bool,
	forwarded:        Maybe(Forwarded_JSON),
	replies:          Maybe(Replies_JSON), // a thread's first message's
	file:             Maybe(File_JSON), // a file offered in a DM
	system:           Maybe(System_JSON), // what happened (a call)
}

Server_JSON :: struct {
	name:           string,
	version:        string,
	description:    string,
	icon:           Maybe(string), // a blob id
	max_attachment: u64, // bytes; 0 for no attachments
	registration:   struct {
		open:   bool,
		email:  bool, // takes an email address
		invite: bool, // takes an invite code
	},
}

Token_JSON :: struct {
	token: string,
}

account_json :: proc(m: ^Model, a: ^proto.Account) -> Account_JSON {
	j := Account_JSON {
		id       = id_string(a.id),
		username = a.username,
		display  = a.display,
		bot      = .Bot in a.flags,
		deleted  = .Deleted in a.flags,
		activity = enum_name(a.activity),
		online   = m.online[a.id] > 0,
		roles    = role_ids(a.roles),
	}
	if a.status != "" {
		j.status = a.status
	}
	if a.status_until != 0 {
		j.status_until = iso_time(a.status_until)
	}
	if a.avatar != 0 {
		j.avatar = id_string(a.avatar)
	}
	return j
}

// accounts_json is every account, by id.
accounts_json :: proc(m: ^Model) -> []Account_JSON {
	ids, _ := slice.map_keys(m.accounts, context.temp_allocator)
	slice.sort(ids)
	out := make([]Account_JSON, len(ids), context.temp_allocator)
	for id, i in ids {
		a := &m.accounts[id]
		out[i] = account_json(m, &a.account)
	}
	return out
}

me_json :: proc(m: ^Model) -> Me_JSON {
	a := m.accounts[m.self]
	me := Me_JSON {
		id       = id_string(m.self),
		username = a.username,
		display  = a.display,
		bot      = .Bot in m.flags,
		owner    = .Owner in m.flags,
		activity = enum_name(a.activity),
		roles    = role_ids(a.roles),
	}
	if a.status != "" {
		me.status = a.status
	}
	if a.status_until != 0 {
		me.status_until = iso_time(a.status_until)
	}
	if a.avatar != 0 {
		me.avatar = id_string(a.avatar)
	}
	me.permissions = permission_names(m.permissions)
	return me
}

role_json :: proc(r: ^proto.Role) -> Role_JSON {
	j := Role_JSON {
		id          = id_string(r.id),
		name        = r.name,
		position    = int(r.position),
		permissions = permission_names(r.perms),
		mentionable = .Mentionable in r.flags,
		everyone    = r.id == proto.EVERYONE_ROLE,
	}
	if r.color & proto.ROLE_COLOR_SET != 0 {
		j.color = fmt.tprintf("#%06x", r.color & 0xFF_FF_FF)
	}
	return j
}

// roles_json is every role, top first: by position, then id, everyone's
// last.
roles_json :: proc(m: ^Model) -> []Role_JSON {
	roles := make([]^proto.Role, len(m.roles), context.temp_allocator)
	n := 0
	for _, &r in m.roles {
		roles[n] = &r.role
		n += 1
	}
	slice.sort_by(roles, proc(a, b: ^proto.Role) -> bool {
		if (a.id == proto.EVERYONE_ROLE) != (b.id == proto.EVERYONE_ROLE) {
			return b.id == proto.EVERYONE_ROLE
		}
		if a.position != b.position {
			return a.position < b.position
		}
		return a.id < b.id
	})
	out := make([]Role_JSON, len(roles), context.temp_allocator)
	for r, i in roles {
		out[i] = role_json(r)
	}
	return out
}

conv_json :: proc(m: ^Model, c: ^proto.Conv) -> Conv_JSON {
	j := Conv_JSON {
		id       = id_string(c.id),
		kind     = enum_name(c.kind),
		name     = c.name,
		topic    = c.topic,
		home     = .Home in c.flags,
		private  = .Private in c.flags,
		position = c.position,
		member   = c.member,
		unread   = c.unread,
		mentions = c.mentions,
		notify   = enum_name(c.notify),
	}
	if c.kind == .DM {
		j.recipient = id_string(c.b if c.a == m.self else c.a)
	}
	if c.last != 0 {
		j.last_message_id = id_string(c.last)
	}
	if c.last_time != 0 {
		j.last_message_timestamp = iso_time(c.last_time)
	}
	if c.read != 0 {
		j.last_read_id = id_string(c.read)
	}
	return j
}

/*
convs_json is the conversations the account is in, as a client lists
them: the channels by position (then id), then the DMs, the most
recently written to first.
*/
convs_json :: proc(m: ^Model) -> []Conv_JSON {
	convs := make([]^proto.Conv, len(m.convs), context.temp_allocator)
	n := 0
	for _, &c in m.convs {
		convs[n] = &c.conv
		n += 1
	}
	slice.sort_by(convs, proc(a, b: ^proto.Conv) -> bool {
		if a.kind != b.kind {
			return a.kind == .Channel
		}
		if a.kind == .DM {
			if a.last_time != b.last_time {
				return a.last_time > b.last_time
			}
			return a.id > b.id
		}
		if a.position != b.position {
			return a.position < b.position
		}
		return a.id < b.id
	})
	out := make([]Conv_JSON, len(convs), context.temp_allocator)
	for c, i in convs {
		out[i] = conv_json(m, c)
	}
	return out
}

author_json :: proc(m: ^Model, id: proto.Account_Id) -> Author_JSON {
	j := Author_JSON {
		id = id_string(id),
	}
	if a, ok := m.accounts[id]; ok {
		j.username, j.display, j.bot = a.username, a.display, .Bot in a.flags
	}
	return j
}

message_json :: proc(m: ^Model, msg: ^proto.Message) -> Message_JSON {
	j := Message_JSON {
		id          = id_string(msg.id),
		conv_id     = id_string(msg.conv),
		author      = author_json(m, msg.sender),
		timestamp   = iso_time(msg.time),
		kind        = enum_name(msg.kind),
		content     = msg.text,
		pinned      = .Pinned in msg.flags,
		deleted     = .Deleted in msg.flags,
		attachments = make([]Attachment_JSON, msg.attachment_count, context.temp_allocator),
	}
	if msg.edited != 0 {
		j.edited_timestamp = iso_time(msg.edited)
	}
	if msg.thread_root != 0 {
		j.thread = id_string(msg.thread_root)
	}
	for a, i in msg.attachments[:msg.attachment_count] {
		j.attachments[i] = {
			name = a.name,
			size = a.size,
		}
		if a.blob != 0 {
			j.attachments[i].id = id_string(a.blob)
		}
	}
	buf: [proto.MAX_REACTIONS]proto.Reaction
	reactions := proto.reactions_of(msg^, buf[:])
	j.reactions = make([]Reaction_JSON, len(reactions), context.temp_allocator)
	for r, i in reactions {
		j.reactions[i] = {r.emoji, r.count, r.me}
	}
	if .Forwarded in msg.flags {
		j.forwarded = Forwarded_JSON {
			author_id = id_string(msg.forward.sender),
			conv_id   = id_string(msg.forward.conv),
			timestamp = iso_time(msg.forward.time),
		}
	}
	if .Has_Thread in msg.flags {
		j.replies = Replies_JSON {
			count   = int(msg.reply_count),
			last_id = id_string(msg.last_reply),
		}
	}
	#partial switch msg.kind {
	case .File:
		j.file = File_JSON{msg.file_name, msg.file_size}
	case .System:
		j.system = System_JSON{int(msg.system), int(msg.system_arg)}
	}
	return j
}

messages_json :: proc(m: ^Model, msgs: []proto.Message) -> []Message_JSON {
	out := make([]Message_JSON, len(msgs), context.temp_allocator)
	for &msg, i in msgs {
		out[i] = message_json(m, &msg)
	}
	return out
}

server_json :: proc(info: ^proto.Server_Info) -> Server_JSON {
	s := Server_JSON {
		name           = info.name,
		version        = info.version,
		description    = info.description,
		max_attachment = info.max_attachment,
	}
	if info.icon != 0 {
		s.icon = id_string(info.icon)
	}
	s.registration.open = .Open in info.registration
	s.registration.email = .Email in info.registration
	s.registration.invite = .Invite in info.registration
	return s
}

// id_string is an id as JSON has it: a string, as u64s don't survive
// JavaScript's numbers.
id_string :: proc(id: $T) -> string {
	return fmt.tprintf("%d", u64(id))
}

// iso_time is Unix milliseconds as ISO 8601, in UTC.
iso_time :: proc(ms: proto.Unix_Ms) -> string {
	t := time.unix(i64(ms / 1000), i64(ms % 1000) * 1_000_000)
	y, mon, d := time.date(t)
	h, mi, s := time.clock(t)
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", y, int(mon), d, h, mi, s, ms % 1000)
}

// enum_name is an enum value's name as JSON has it: in lower case.
enum_name :: proc(v: $T) -> string {
	return strings.to_lower(reflect.enum_string(v), context.temp_allocator)
}

@(private)
permission_names :: proc(perms: proto.Permissions) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for p in perms {
		append(&out, enum_name(p))
	}
	return out[:]
}

@(private)
role_ids :: proc(roles: []proto.Role_Id) -> []string {
	out := make([]string, len(roles), context.temp_allocator)
	for r, i in roles {
		out[i] = id_string(r)
	}
	return out
}
