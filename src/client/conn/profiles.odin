package conn

import log "common:wlog"
import "core:crypto/hash"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"

import "common:proto"

/*
What people say about themselves, and what we keep on the server for
ourselves (src/common/proto/accounts.odin, settings.odin):

  - Our status: a line of text, and when it ends by itself (the server
    clears it). Everyone's comes with their account (auth.odin).
  - Our picture: a JPEG the UI has made square and small, uploaded as a
    blob of kind Avatar through the outbox (messages.odin) and then set
    with Profile_Set. Other people's are fetched like a message's
    picture (blobs.odin), when the UI first shows them.
  - Our account's settings: kept by key, as text, by the server. The
    login sync brings them all; a change from another of our devices
    comes as Setting_Changed. The UI decides what they mean and keeps a
    copy of its own, so they apply before the sync. What we change goes
    to the server, and to the View at once.
  - A conversation's members, for the UI's members panel.

The setting `ui/view` is the conversation last looked at, on whichever
device: a fresh start on any of them opens it.
*/

// The setting that says which conversation was looked at last.
SETTING_VIEW :: "ui/view"

Profile_Client :: struct {
	// The account's settings as the server has them; keys and values
	// owned.
	shared:       map[string]string,
	// The sync has brought them all (Sync_End).
	synced:       bool,
	// `ui/view` has been acted on, once for this client.
	view_applied: bool,
	// How many syncs have brought them.
	syncs:        int,
	// The conversation whose members were asked for last.
	members_conv: proto.Conv_Id,
}

// Set our status: `text` ("" for none), ending at `until` (0: never).
Status_Command :: struct {
	text:  string, // owned by the command
	until: proto.Unix_Ms,
}
// Set our picture, a JPEG the UI has made (taken over), or with `remove`,
// have none.
Avatar_Command :: struct {
	image:  Chat_Image,
	remove: bool,
}
// Fetch somebody's picture, which the UI is about to show.
Avatar_Want_Command :: struct {
	blob: proto.Blob_Id,
}
// Change one of the account's settings; an empty value removes it.
Setting_Command :: struct {
	key:   string, // owned by the command
	value: string, // owned by the command
}
// Fetch a conversation's members (0: the one we're looking at).
Members_Command :: struct {
	conv: proto.Conv_Id,
}

profiles_destroy :: proc(c: ^Voice_Client) {
	shared_clear(c)
	delete(c.profiles.shared)
	c.profiles = {}
}

@(private = "file")
shared_clear :: proc(c: ^Voice_Client) {
	for k, v in c.profiles.shared {
		delete(k)
		delete(v)
	}
	clear(&c.profiles.shared)
}

// shared_begin: the sync starts, and brings every setting there is.
shared_begin :: proc(c: ^Voice_Client) {
	shared_clear(c)
	c.profiles.synced = false
	publish_shared(c)
}

// shared_end: the sync is over, and what we have is all there is.
shared_end :: proc(c: ^Voice_Client) {
	c.profiles.synced = true
	c.profiles.syncs += 1
	publish_shared(c)
	if c.view == nil {
		log.infof("[settings] %d kept on the server", len(c.profiles.shared))
	}
}

// shared_view is the conversation looked at last on any of our devices,
// once for a client: where a fresh start opens (convs_synced).
shared_view :: proc(c: ^Voice_Client) -> proto.Conv_Id {
	p := &c.profiles
	if p.view_applied {
		return 0
	}
	p.view_applied = true
	id, ok := strconv.parse_u64(p.shared[SETTING_VIEW] or_else "")
	return proto.Conv_Id(id) if ok else 0
}

// shared_viewed notes the conversation looked at, for our other devices.
shared_viewed :: proc(c: ^Voice_Client, conv: proto.Conv_Id) {
	if !c.profiles.synced || conv == 0 {
		return
	}
	setting_put(c, SETTING_VIEW, fmt.tprint(u32(conv)))
}

// profiles_event takes an event about settings; false if `op` isn't one.
profiles_event :: proc(c: ^Voice_Client, op: proto.Event_Op, body: []u8) -> bool {
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
shared_store :: proc(c: ^Voice_Client, key, value: string) {
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

// setting_put changes one of the account's settings, here and on the
// server; no request if it's that already.
setting_put :: proc(c: ^Voice_Client, key, value: string) {
	if !proto.setting_key_ok(key) || len(value) > proto.MAX_SETTING_VALUE {
		return
	}
	if (c.profiles.shared[key] or_else "") == value {
		return
	}
	shared_store(c, key, value)
	buf: [proto.SETTING_MAX_SIZE]u8
	request(c, .Setting_Set, proto.encode_setting(buf[:], key, transmute([]u8)value), proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
		#partial switch status {
		case .Ok, .Reset:
		case .Too_Large:
			log.warn("the server keeps no more settings for this account")
		case:
			log.warnf("the server wouldn't keep a setting (%v)", status)
		}
	})
}

// status_set sets our status.
status_set :: proc(c: ^Voice_Client, raw: string, until: proto.Unix_Ms) {
	buf: [proto.MAX_STATUS_SIZE]u8
	text := proto.sanitize_text(raw, buf[:])
	body_buf: [proto.ACCOUNT_BODY_MAX + proto.MAX_STATUS_SIZE]u8
	body := proto.encode_profile_set(body_buf[:], {mask = proto.PROFILE_STATUS, status = text, status_until = until if text != "" else 0})
	request(c, .Profile_Set, body, profile_done)
}

// avatar_set puts our new picture in the outbox, to be uploaded and then
// set (drive_outbox); it takes over the JPEG. With `remove` we have none.
avatar_set :: proc(c: ^Voice_Client, image: Chat_Image, remove: bool) {
	if remove {
		buf: [proto.ACCOUNT_BODY_MAX]u8
		request(c, .Profile_Set, proto.encode_profile_set(buf[:], {mask = proto.PROFILE_AVATAR}), profile_done)
		return
	}
	if len(image.jpeg) == 0 ||
	   len(image.jpeg) > proto.MAX_AVATAR_SIZE ||
	   image.width > proto.MAX_AVATAR_SIDE ||
	   image.height > proto.MAX_AVATAR_SIDE {
		log.warnf("not setting a picture of %d bytes, %dx%d", len(image.jpeg), image.width, image.height)
		delete(image.jpeg)
		return
	}
	p := Pending {
		nonce  = new_nonce(),
		avatar = true,
		kind   = .Image,
		jpeg   = image.jpeg,
		state  = .Put,
		put    = {kind = .Avatar, size = len(image.jpeg), width = image.width, height = image.height},
	}
	hash.hash_bytes_to_buffer(.SHA256, image.jpeg, p.put.hash[:])
	append(&c.msgs.outbox, p)
	publish_outbox(c)
}

// avatar_post sets the picture that's just been uploaded (the outbox's
// last step for one).
avatar_post :: proc(c: ^Voice_Client, p: ^Pending) {
	buf: [proto.ACCOUNT_BODY_MAX]u8
	request(c, .Profile_Set, proto.encode_profile_set(buf[:], {mask = proto.PROFILE_AVATAR, avatar = p.blob}), proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
		p := outbox_head(c, tag)
		if p == nil || !p.avatar {
			return
		}
		p.asking = false
		#partial switch status {
		case .Ok:
		case .Reset:
			return // set again on the new connection
		case .Not_Found:
			// The picture has gone from the server; send it again.
			p.blob, p.state = 0, .Put
			return
		case:
			outbox_give_up(c, "Your picture wasn't set: the server wouldn't take it.")
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
	}, p.nonce)
}

@(private = "file")
profile_done :: proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
	if status != .Ok && status != .Reset {
		notify(c, false, status_text(status))
	}
}

// members_fetch asks for a conversation's members, for the UI's panel
// (and headless, the log).
members_fetch :: proc(c: ^Voice_Client, conv: proto.Conv_Id) {
	if conv == 0 {
		return
	}
	c.profiles.members_conv = conv
	publish_members(c, conv, nil, true)
	buf: [4]u8
	request(c, .Conv_Members, proto.encode_conv_id(&buf, conv), proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
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
	}, u64(conv))
}

/*
What the UI is shown.
*/

// A conversation's members, as the members panel shows them.
View_Members :: struct {
	conv:     proto.Conv_Id,
	accounts: [dynamic]proto.Account_Id,
	loading:  bool,
	count:    int, // bumped whenever they arrive
}

@(private = "file")
publish_shared :: proc(c: ^Voice_Client) {
	v := c.view
	if v == nil {
		return
	}
	sync.guard(&v.mutex)
	view_clear_shared(v)
	for k, value in c.profiles.shared {
		v.shared[strings.clone(k)] = strings.clone(value)
	}
	v.shared_synced = c.profiles.synced
	v.shared_syncs = c.profiles.syncs
	v.shared_count += 1
}

@(private = "file")
publish_members :: proc(c: ^Voice_Client, conv: proto.Conv_Id, accounts: []proto.Account_Id, loading: bool) {
	v := c.view
	if v == nil {
		return
	}
	sync.guard(&v.mutex)
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
