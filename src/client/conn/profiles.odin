package conn

import log "common:wlog"
import "core:crypto/hash"
import "core:fmt"
import "core:strconv"
import "core:strings"

import "common:proto"

// What people say about themselves, and what we keep on the server for
// ourselves (src/common/proto/accounts.odin, settings.odin):
//
//   - Our status: a line of text, and when it expires on its own (the server
//     clears it). Everyone's status comes with their account (auth.odin).
//   - Our picture: a JPEG that the UI has made square and small. It is uploaded
//     as a blob of kind Avatar through the outbox (messages.odin) and then set
//     with Profile_Set. Other people's pictures are fetched like a message's
//     picture (blobs.odin) when the UI first shows them.
//   - Our account's settings: stored by the server as text, by key. The login
//     sync brings all of them, and a change from another of our devices comes
//     as Setting_Changed. The UI decides what they mean and keeps a copy of its
//     own, so the settings apply before the sync. What we change goes to the
//     server and to the View immediately.
//   - A conversation's members, for the UI's members panel.
//
// The setting `ui/view` is the conversation that was looked at last, on any of
// our devices: a fresh start on any device opens it.

// The setting that stores which conversation was looked at last.
SETTING_VIEW :: "ui/view"

// The setting that says whether our activity, status and talking in a voice
// chat or a call are shared between this server and the other servers we are
// connected to (see the UI's status_sync and sounds_frame): STATUS_SHARED_OFF
// if not, for an account that has nothing to do with our accounts elsewhere.
// If it isn't set, they are shared.
SETTING_STATUS_SHARED :: "status/shared"
STATUS_SHARED_OFF :: "off"

Profile_Client :: struct {
	// The account's settings as the server has them. Keys and values are
	// owned.
	shared:       map[string]string,
	// The sync has brought all of them (Sync_End).
	synced:       bool,
	// `ui/view` has been applied, once for this client.
	view_applied: bool,
	// How many syncs have brought the settings.
	syncs:        int,
	// The conversation whose members were requested last.
	members_conv: proto.Conv_Id,
}

// Set our status: `text` ("" for none), expiring at `until` (0: never). It
// is set now, or with `at`, it is the status set then on another server.
Status_Command :: struct {
	text:  string, // owned by the command
	until: proto.Unix_Ms,
	at:    proto.Unix_Ms,
}
// Set our picture to a JPEG that the UI has made (the command takes ownership
// of it), or with `remove`, remove it.
Avatar_Command :: struct {
	image:  Chat_Image,
	remove: bool,
}
// Fetch somebody's picture, which the UI is about to show.
Avatar_Want_Command :: struct {
	blob: proto.Blob_Id,
}
// Change one of the account's settings. An empty value removes it.
Setting_Command :: struct {
	key:   string, // owned by the command
	value: string, // owned by the command
}
// Fetch a conversation's members (0: the one we're looking at).
Members_Command :: struct {
	conv: proto.Conv_Id,
}

profiles_destroy :: proc(c: ^Server_Conn) {
	shared_clear(c)
	delete(c.profiles.shared)
	c.profiles = {}
}

@(private = "file")
shared_clear :: proc(c: ^Server_Conn) {
	for k, v in c.profiles.shared {
		delete(k)
		delete(v)
	}
	clear(&c.profiles.shared)
}

// shared_begin is called when the sync starts, which brings every setting.
shared_begin :: proc(c: ^Server_Conn) {
	shared_clear(c)
	c.profiles.synced = false
	publish_shared(c)
}

// shared_end is called when the sync is over, so we now have every setting.
shared_end :: proc(c: ^Server_Conn) {
	c.profiles.synced = true
	c.profiles.syncs += 1
	publish_shared(c)
	if c.view == nil {
		log.infof("[settings] %d kept on the server", len(c.profiles.shared))
	}
}

// shared_view is the conversation that was looked at last on any of our
// devices. It is applied once per client, and a fresh start opens it (convs_synced).
shared_view :: proc(c: ^Server_Conn) -> proto.Conv_Id {
	p := &c.profiles
	if p.view_applied {
		return 0
	}
	p.view_applied = true
	id, ok := strconv.parse_u64(p.shared[SETTING_VIEW] or_else "")
	return proto.Conv_Id(id) if ok else 0
}

// shared_viewed records the conversation being looked at, for our other devices.
shared_viewed :: proc(c: ^Server_Conn, conv: proto.Conv_Id) {
	if !c.profiles.synced || conv == 0 {
		return
	}
	setting_put(c, SETTING_VIEW, fmt.tprint(u32(conv)))
}

// profiles_event handles an event about settings. Returns false if `op` is not one.
profiles_event :: proc(c: ^Server_Conn, op: proto.Event_Op, body: []u8) -> bool {
	if op != .Setting_Changed {
		return false
	}
	key, value, ok := proto.decode_setting(body)
	if !ok || !proto.setting_key_ok(key) {
		return true
	}
	shared_store(c, key, string(value))
	if c.view == nil && c.profiles.synced {
		log.infof("[settings] %s = %q", key, string(value))
	}
	return true
}

@(private = "file")
shared_store :: proc(c: ^Server_Conn, key, value: string) {
	p := &c.profiles
	if key in p.shared {
		old_key, old_value := delete_key(&p.shared, key)
		delete(old_key)
		delete(old_value)
	}
	if value != "" {
		p.shared[strings.clone(key)] = strings.clone(value)
	}
	publish_shared(c)
}

// setting_put changes one of the account's settings, here and on the server.
// No request is sent if the setting already has that value.
setting_put :: proc(c: ^Server_Conn, key, value: string) {
	if !proto.setting_key_ok(key) || len(value) > proto.MAX_SETTING_VALUE {
		return
	}
	if (c.profiles.shared[key] or_else "") == value {
		return
	}
	shared_store(c, key, value)
	buf: [proto.SETTING_MAX_SIZE]u8
	request(
		c,
		.Setting_Set,
		proto.encode_setting(buf[:], key, transmute([]u8)value),
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			#partial switch status {
			case .Ok, .Reset:
			case .Too_Large:
				log.warn("the server keeps no more settings for this account")
			case:
				log.warnf("the server wouldn't keep a setting (%v)", status)
			}
		},
	)
}

// status_set sets our status.
status_set :: proc(c: ^Server_Conn, raw: string, until: proto.Unix_Ms, at: proto.Unix_Ms) {
	buf: [proto.MAX_STATUS_SIZE]u8
	text := proto.sanitize_text(raw, buf[:])
	body_buf: [proto.ACCOUNT_BODY_MAX + proto.MAX_STATUS_SIZE + 8]u8
	body := proto.encode_profile_set(
		body_buf[:],
		{
			mask = proto.PROFILE_STATUS,
			status = text,
			status_until = until if text != "" else 0,
			status_at = at,
		},
	)
	request(c, .Profile_Set, body, profile_done)
}

// avatar_set puts our new picture in the outbox, to be uploaded and then
// set (drive_outbox). It takes over the JPEG. With `remove` we have none.
avatar_set :: proc(c: ^Server_Conn, image: Chat_Image, remove: bool) {
	if remove {
		buf: [proto.ACCOUNT_BODY_MAX]u8
		request(
			c,
			.Profile_Set,
			proto.encode_profile_set(buf[:], {mask = proto.PROFILE_AVATAR}),
			profile_done,
		)
		return
	}
	if len(image.jpeg) == 0 ||
	   len(image.jpeg) > proto.MAX_AVATAR_SIZE ||
	   image.width > proto.MAX_AVATAR_SIDE ||
	   image.height > proto.MAX_AVATAR_SIDE {
		log.warnf(
			"not setting a picture of %d bytes, %dx%d",
			len(image.jpeg),
			image.width,
			image.height,
		)
		delete(image.jpeg)
		return
	}
	p := Pending {
		nonce = new_nonce(),
		avatar = true,
		jpeg = image.jpeg,
		state = .Put,
		put = {kind = .Avatar, size = len(image.jpeg), width = image.width, height = image.height},
	}
	hash.hash_bytes_to_buffer(.SHA256, image.jpeg, p.put.hash[:])
	append(&c.msgs.outbox, p)
	publish_outbox(c)
}

// avatar_post sets the picture that was just uploaded (the last step of the
// outbox entry for one).
avatar_post :: proc(c: ^Server_Conn, p: ^Pending) {
	buf: [proto.ACCOUNT_BODY_MAX]u8
	request(
		c,
		.Profile_Set,
		proto.encode_profile_set(buf[:], {mask = proto.PROFILE_AVATAR, avatar = p.blob}),
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			p := outbox_head(c, tag)
			if p == nil || !p.avatar || p.server {
				return
			}
			p.asking = false
			#partial switch status {
			case .Ok:
			case .Reset:
				return // set again on the new connection
			case .Not_Found:
				// The picture has disappeared from the server, so send it again.
				p.blob, p.state = 0, .Put
				return
			case:
				outbox_give_up(c, "The server rejected your new picture.")
				return
			}
			blob_have(c, p.blob, p.jpeg, p.put.width, p.put.height)
			p.jpeg = nil
			pending_destroy(p)
			ordered_remove(&c.msgs.outbox, 0)
			publish_outbox(c)
			if c.view == nil {
				log.info("[status] picture set")
			}
		},
		p.nonce,
	)
}

@(private = "file")
profile_done :: proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
	if status != .Ok && status != .Reset {
		notify(c, false, status_text(status))
	}
}

// members_fetch asks for a conversation's members, for the UI's panel (or for
// the log when headless).
members_fetch :: proc(c: ^Server_Conn, conv: proto.Conv_Id) {
	if conv == 0 {
		return
	}
	c.profiles.members_conv = conv
	publish_members(c, conv, nil, true)
	buf: [4]u8
	request(
		c,
		.Conv_Members,
		proto.encode_conv_id(&buf, conv),
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			conv := proto.Conv_Id(tag)
			if c.profiles.members_conv != conv {
				return
			}
			if status != .Ok {
				publish_members(c, conv, nil, false)
				return
			}
			buf := make([]proto.Account_Id, max(len(body) / 4, 1), context.temp_allocator)
			members, ok := proto.decode_conv_members(body, buf)
			if !ok {
				publish_members(c, conv, nil, false)
				return
			}
			publish_members(c, conv, members, false)
			if c.view == nil {
				for m in members {
					acc := c.auth.accounts[m] or_else {}
					log.infof(
						"[members] %s: %s%s%s",
						room_name(c, proto.Room(conv)),
						account_display(c, m),
						" (here)" if is_online(c, m) else "",
						fmt.tprintf(" - %s", acc.status) if acc.status != "" else "",
					)
				}
			}
		},
		u64(conv),
	)
}

// What the UI is shown.

// A conversation's members, as the members panel shows them.
View_Members :: struct {
	conv:     proto.Conv_Id,
	accounts: [dynamic]proto.Account_Id,
	loading:  bool,
	count:    int, // incremented whenever they arrive
}

@(private = "file")
publish_shared :: proc(c: ^Server_Conn) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	view_clear_shared(v)
	for k, value in c.profiles.shared {
		v.shared[strings.clone(k)] = strings.clone(value)
	}
	v.shared_synced = c.profiles.synced
	v.shared_syncs = c.profiles.syncs
	v.shared_count += 1
}

@(private = "file")
publish_members :: proc(
	c: ^Server_Conn,
	conv: proto.Conv_Id,
	accounts: []proto.Account_Id,
	loading: bool,
) {
	v := c.view
	if v == nil {
		return
	}
	view_write(v)
	if v.members.conv != conv || !loading {
		clear(&v.members.accounts)
	}
	v.members.conv = conv
	append(&v.members.accounts, ..accounts)
	v.members.loading = loading
	v.members.count += 1
}

// Call with the mutex held.
view_clear_shared :: proc(v: ^View) {
	for k, value in v.shared {
		delete(k)
		delete(value)
	}
	clear(&v.shared)
}
