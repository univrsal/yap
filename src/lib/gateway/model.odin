package gateway

import "core:fmt"
import "core:reflect"
import "core:slice"
import "core:strings"
import "core:time"

import "common:proto"

// This is what the gateway keeps for each connection (docs/bot-api, "What the
// gateway keeps"). The protocol sends a client everything when it logs in and
// afterwards only what changes, and it has no request for most of that data,
// so GET requests are answered from this model. It is rebuilt on every
// Sync_Begin..Sync_End.
//
// The model holds who the connection is (Self), the roles, the accounts, the
// conversations the account is in together with what it has read of each, and
// who is online (the snapshots). A conversation's newest message and its
// unread count follow the incoming messages, counted the way a client counts
// them. Mentions since the last Read_Changed are not counted, because that
// requires knowing who a mention is for, which the server only says when it
// reports what has been read.

Model :: struct {
	self:         proto.Account_Id, // 0 until Self arrives
	permissions:  proto.Permissions,
	flags:        proto.Account_Flags,
	roles:        map[proto.Role_Id]Role_Record,
	accounts:     map[proto.Account_Id]Account_Record,
	convs:        map[proto.Conv_Id]Conv_Record,
	// How many connections each account has here. Accounts that appear
	// offline are not included because the server leaves them out.
	online:       map[proto.Account_Id]int,
	// What the server reports about itself. It is requested once and then
	// kept up to date with Server_Info events. Its strings are owned.
	server:       proto.Server_Info,
	server_known: bool,
}

// The records as the model stores them. They own their strings (and roles).
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

// model_clear forgets everything that a sync sends again. Who is online is
// delivered by the snapshots, which continue to arrive, so it is kept.
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
		// The complete current state follows.
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
		id, ok := proto.decode_conv_id(body) // a u32, like a conversation's id
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
			// Posting a message marks everything up to it as read.
			c.read, c.unread, c.mentions = msg.id, 0, 0
		case msg.id > c.read:
			c.unread = min(c.unread + 1, proto.UNREAD_CAP)
		}
	}
}

// model_server stores what the server reports about itself.
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

// model_state stores a snapshot of who is online.
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

// account_name returns the account of a connection, for the log.
account_name :: proc(c: ^Conn) -> string {
	if a, ok := c.model.accounts[c.model.self]; ok {
		return a.username
	}
	return fmt.tprintf("account %d", c.model.self)
}

// JSON (docs/bot-api, "Messages as JSON"): ids are strings, times are ISO 8601
// in UTC, absent values are null, and Discord's names are used where the thing
// is the same. Everything created here is allocated with the temp allocator.

Account_JSON :: struct {
	id:           string,
	username:     string,
	display:      string,
	bot:          bool,
	deleted:      bool,
	status:       Maybe(string),
	status_until: Maybe(string),
	avatar:       Maybe(string), // a blob id
	activity:     string, // online, away, busy or offline, as the account set it
	online:       bool, // connected now and not appearing offline
	roles:        []string,
	server_muted: bool, // muted for everyone by a moderator
}

// What /me returns: the account and what it is allowed to do.
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
	permissions:  []string, // beyond those of everyone, e.g. manage_messages
	server_muted: bool, // muted for everyone by a moderator
}

Role_JSON :: struct {
	id:          string,
	name:        string,
	color:       Maybe(string), // "#rrggbb"
	position:    int, // a lower value is listed higher up
	permissions: []string,
	mentionable: bool,
	everyone:    bool, // the role that every account has
}

Conv_JSON :: struct {
	id:                     string,
	kind:                   string, // channel, dm, group
	name:                   string,
	topic:                  string,
	home:                   bool, // the channel that everyone is in
	private:                bool,
	default:                bool, // new accounts are put in it
	text_only:              bool, // it has no voice room
	// What the account may do there: see, write, react, edit, delete, voice.
	rights:                 []string,
	position:               int,
	// A DM's other account, or the account itself in a DM with oneself.
	recipient:              Maybe(string),
	// A group's other accounts.
	members:                Maybe([]string),
	member:                 bool,
	last_message_id:        Maybe(string),
	last_message_timestamp: Maybe(string),
	// What the account has read, if it is a member.
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
	id:   Maybe(string), // the file's blob id, null once it has been removed
	name: string,
	size: u64,
}

Reaction_JSON :: struct {
	emoji: string, // the character, or :name: for one of the server's own emoji
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
	thread:           Maybe(string), // the first message of the thread, if it is in one
	attachments:      []Attachment_JSON,
	reactions:        []Reaction_JSON,
	pinned:           bool,
	deleted:          bool,
	forwarded:        Maybe(Forwarded_JSON),
	replies:          Maybe(Replies_JSON), // set on the first message of a thread
	file:             Maybe(File_JSON), // a file offered in a DM
	system:           Maybe(System_JSON), // what happened, e.g. a call
}

Server_JSON :: struct {
	name:           string,
	version:        string,
	description:    string,
	icon:           Maybe(string), // a blob id
	max_attachment: u64, // in bytes, 0 if attachments are not allowed
	registration:   struct {
		open:   bool,
		email:  bool, // asks for an email address
		invite: bool, // asks for an invite code
	},
}

Token_JSON :: struct {
	token: string,
}

account_json :: proc(m: ^Model, a: ^proto.Account) -> Account_JSON {
	j := Account_JSON {
		id           = id_string(a.id),
		username     = a.username,
		display      = a.display,
		bot          = .Bot in a.flags,
		deleted      = .Deleted in a.flags,
		activity     = enum_name(a.activity),
		online       = m.online[a.id] > 0,
		roles        = role_ids(a.roles),
		server_muted = .Server_Muted in a.flags,
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

// accounts_json returns every account, sorted by id.
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
		id           = id_string(m.self),
		username     = a.username,
		display      = a.display,
		bot          = .Bot in m.flags,
		owner        = .Owner in m.flags,
		activity     = enum_name(a.activity),
		roles        = role_ids(a.roles),
		server_muted = .Server_Muted in m.flags,
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

// roles_json returns every role, top first: sorted by position, then by id,
// with the everyone role last.
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
		id        = id_string(c.id),
		kind      = enum_name(c.kind),
		name      = c.name,
		topic     = c.topic,
		home      = .Home in c.flags,
		private   = .Private in c.flags,
		default   = .Default in c.flags,
		text_only = .Text_Only in c.flags,
		position  = c.position,
		member    = c.member,
		unread    = c.unread,
		mentions  = c.mentions,
		notify    = enum_name(c.notify),
	}
	switch c.kind {
	case .Channel:
	case .DM:
		j.recipient = id_string(m.self) // until someone else is found: a DM with oneself
		for a in proto.conv_accounts(c) {
			if a != m.self {
				j.recipient = id_string(a)
			}
		}
	case .Group:
		others := make([dynamic]string, 0, proto.MAX_GROUP_MEMBERS, context.temp_allocator)
		for a in proto.conv_accounts(c) {
			if a != m.self {
				append(&others, id_string(a))
			}
		}
		j.members = others[:]
	}
	rights := make([dynamic]string, 0, len(proto.Conv_Right), context.temp_allocator)
	for r in c.rights {
		append(&rights, enum_name(r))
	}
	j.rights = rights[:]
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

// convs_json returns the conversations the account is in, ordered like a
// client lists them: the channels by position (then id), followed by the DMs
// and groups, with the most recently active first.
convs_json :: proc(m: ^Model) -> []Conv_JSON {
	convs := make([]^proto.Conv, len(m.convs), context.temp_allocator)
	n := 0
	for _, &c in m.convs {
		convs[n] = &c.conv
		n += 1
	}
	slice.sort_by(convs, proc(a, b: ^proto.Conv) -> bool {
		if (a.kind == .Channel) != (b.kind == .Channel) {
			return a.kind == .Channel
		}
		if a.kind != .Channel {
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

// id_string returns an id as a JSON string, because a u64 doesn't survive
// being a JavaScript number.
id_string :: proc(id: $T) -> string {
	return fmt.tprintf("%d", u64(id))
}

// iso_time formats Unix milliseconds as ISO 8601 in UTC.
iso_time :: proc(ms: proto.Unix_Ms) -> string {
	t := time.unix(i64(ms / 1000), i64(ms % 1000) * 1_000_000)
	y, mon, d := time.date(t)
	h, mi, s := time.clock(t)
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", y, int(mon), d, h, mi, s, ms % 1000)
}

// enum_name returns an enum value's name in lower case, as used in JSON.
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
