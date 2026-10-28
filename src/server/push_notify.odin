package server

import "core:encoding/json"
import "core:fmt"
import "core:strings"

import "common:proto"
import "webpush"

// What gets pushed (webpush/webpush.odin), and to whom: the same things a desktop client would show
// as a desktop notification (src/client/ui_notices.odin), for users who aren't around to
// see them.
//
//   - A message in a DM is pushed to the other participant, and a message that mentions
//     someone is pushed to each mentioned member, unless they muted the conversation
//     (Notify_Level.None). Not every message in a channel set to notify about every
//     message (Notify_Level.All, the default for channels) is pushed: the desktop client
//     doesn't do that either, and a phone that buzzed for every message would soon have
//     push turned off.
//   - Pushes only go to accounts that are away: they have no connection, or all of their
//     connections are idle or hidden (activity.odin; the web client reports when its page
//     is hidden). Someone at their desktop gets the desktop notification instead.
//   - A push is sent to every subscription of the account (push_subs.odin).
//
//   - A call (calls.odin) is pushed to a callee that is away: "Alice is calling you". Once
//     the call is over, that notification is replaced by one for a missed call, or
//     (silently, and not to the device that handled it) one saying it was answered or
//     declined elsewhere. A push can't remove a notification (see docs/design/mobile.md, phase 3),
//     but it can replace it with another one.
//
// A push carries JSON for the service worker (web/sw.js) to display:
//
//	{"kind": "dm" | "mention" | "call", "server": <its name>,
//	 "conv": <id>, "msg": <id>, "title": "Alice messaged you",
//	 "body": <the text>, "tag": <its notification>, "quiet": <no sound>,
//	 "ring": <a call ringing>}
//
// The body is quoted the same way a digest quotes it (digest_quote), or empty for an
// account that hides message text (proto.SETTING_PUSH_TEXT). Pushes for the same
// conversation share a Topic, so a push service holding several of them for a phone
// that's offline only keeps the newest, and the service worker merges them into one
// notification (by its tag) with a count.

// How long a push service may hold a push for a phone that's offline: anything missed a
// day ago is better read in the client.
PUSH_TTL :: 24 * 60 * 60

// The JSON payload of a push.
Push_Payload :: struct {
	kind:   string,
	server: string,
	conv:   u32,
	msg:    u64,
	title:  string,
	body:   string,
	// The notification this push belongs to: a conversation's ("c<conv>") or a call's;
	// whether it silently replaces an earlier one; and whether it's a ringing call, which
	// stays visible until the user acts on it.
	tag:    string,
	quiet:  bool,
	ring:   bool,
}

// The call events that get pushed.
Push_Call :: enum {
	Ringing,
	Missed,
	Answered,
	Declined,
}

// push_message pushes a new message in `conv` to everyone it concerns who is away: the
// other participant of a DM, the other members of a group, or the members it mentions
// (`mentioned`, as returned by mentions_resolve).
push_message :: proc(s: ^Server, conv: ^Conv, m: proto.Message, mentioned: []proto.Account_Id) {
	if !s.push.enabled || m.kind == .System || .Deleted in m.flags {
		return
	}
	switch conv.kind {
	case .Channel:
	case .DM:
		push_member(s, conv, m, dm_other(conv, m.sender), "dm")
		return
	case .Group:
		for who in conv.members {
			push_member(s, conv, m, who, "group")
		}
		return
	}
	for who in mentioned {
		push_member(s, conv, m, who, "mention")
	}
}

// group_names returns the display names of a group's members other than `a` and
// `b`, as "Bob and Carol" or "Bob, Carol and Dave", in the temp allocator.
group_names :: proc(s: ^Server, conv: ^Conv, a, b: proto.Account_Id) -> string {
	names := make([dynamic]string, context.temp_allocator)
	for id in conv.members {
		if id == a || id == b {
			continue
		}
		acc := account_by_id(&s.accounts, id)
		append(&names, acc.display if acc != nil else "Somebody")
	}
	switch len(names) {
	case 0:
		return ""
	case 1:
		return names[0]
	}
	head := strings.join(names[:len(names) - 1], ", ", context.temp_allocator)
	return fmt.tprintf("%s and %s", head, names[len(names) - 1])
}

// push_away reports whether an account isn't around to see a notification: it has no
// connection, or all of its connections are idle or hidden.
push_away :: proc(acc: ^Account) -> bool {
	for u in acc.conns {
		if !u.idle && !u.hidden {
			return false
		}
	}
	return true
}

@(private = "file")
push_member :: proc(
	s: ^Server,
	conv: ^Conv,
	m: proto.Message,
	who: proto.Account_Id,
	kind: string,
) {
	if who == m.sender || who == 0 {
		return
	}
	acc := account_by_id(&s.accounts, who)
	if acc == nil || acc.flags & {.Disabled, .Deleted, .Unverified} != {} || !push_away(acc) {
		return
	}
	member, is_member := conv.reads[who]
	if !is_member || member.notify == .None {
		return
	}
	payload, ok := push_payload(s, conv, m, kind, who, acc.push_hide)
	if !ok {
		return
	}
	push_to(s, who, payload, fmt.tprintf("c%d", conv.id), PUSH_TTL, .High)
}

// push_reaches reports whether pushes can reach an account: the server supports push, and
// the account has enabled it on at least one device.
push_reaches :: proc(s: ^Server, acc: ^Account) -> bool {
	return s.push.enabled && len(push_subs_of(s, acc.id)) > 0
}

// push_call pushes a call event to its callee: that the call is ringing, if they are away;
// or how a call that was already pushed ended, to every device except `except` (the one
// that handled it). Returns whether anything was pushed.
push_call :: proc(s: ^Server, call: ^Call, what: Push_Call, except: ^Conn = nil) -> bool {
	callee := account_by_id(&s.accounts, call.callee)
	if !s.push.enabled || callee == nil || (what == .Ringing && !push_away(callee)) {
		return false
	}
	caller := account_by_id(&s.accounts, call.caller)
	name := caller.display if caller != nil else "Somebody"
	p := Push_Payload {
		kind   = "call",
		server = s.name,
		tag    = fmt.tprintf("call%d", call.id),
	}
	if dm := dm_find(&s.convs, call.caller, call.callee); dm != nil {
		p.conv = u32(dm.id)
	}
	ttl, urgency := PUSH_TTL, webpush.Urgency.Normal
	switch what {
	case .Ringing:
		p.title = fmt.tprintf("%s is calling you", name)
		p.body = "Open yap to answer."
		p.ring = true
		ttl, urgency = proto.CALL_RING_SECONDS, .High
	case .Missed:
		p.title = fmt.tprintf("Missed call from %s", name)
	case .Answered:
		p.title = fmt.tprintf("Call with %s", name)
		p.body = "Answered on another device."
		p.quiet = true
	case .Declined:
		p.title = fmt.tprintf("Call from %s", name)
		p.body = "You declined the call."
		p.quiet = true
	}
	payload, err := json.marshal(p, allocator = context.temp_allocator)
	if err != nil {
		return false
	}
	skip: [proto.KEY_SIZE]u8
	if except != nil {
		skip = except.key
	}
	return push_to(s, call.callee, payload, p.tag, ttl, urgency, skip) > 0
}

// push_to queues a payload for each of an account's subscriptions, except the one of the
// `skip` device, and returns how many were queued.
@(private = "file")
push_to :: proc(
	s: ^Server,
	who: proto.Account_Id,
	payload: []u8,
	topic: string,
	ttl: int,
	urgency: webpush.Urgency,
	skip: [proto.KEY_SIZE]u8 = {},
) -> (
	sent: int,
) {
	for sub in push_subs_of(s, who) {
		if skip != {} && sub.device == skip {
			continue
		}
		if webpush.send(
			&s.push,
			{
				sub = sub.id,
				account = who,
				endpoint = sub.endpoint,
				p256dh = sub.p256dh,
				auth = sub.auth,
				payload = payload,
				ttl = ttl,
				urgency = urgency,
				topic = topic,
			},
		) {
			sent += 1
		}
	}
	return
}

// push_payload builds the JSON payload of a push, in the temp allocator.
push_payload :: proc(
	s: ^Server,
	conv: ^Conv,
	m: proto.Message,
	kind: string,
	to: proto.Account_Id,
	hide: bool,
) -> (
	payload: []u8,
	ok: bool,
) {
	sender := account_by_id(&s.accounts, m.sender)
	// Deleted accounts are kept as tombstones, so a missing sender shouldn't happen.
	name := sender.display if sender != nil else "Somebody"
	p := Push_Payload {
		kind   = kind,
		server = s.name,
		conv   = u32(conv.id),
		msg    = u64(m.id),
		tag    = fmt.tprintf("c%d", conv.id),
	}
	switch kind {
	case "dm":
		p.title = fmt.tprintf("%s messaged you", name)
	case "group":
		p.title = fmt.tprintf("%s messaged you, %s", name, group_names(s, conv, m.sender, to))
	case:
		p.title = fmt.tprintf("%s mentioned you in #%s", name, conv.name)
	}
	if !hide {
		text := m.text if m.kind == .Text else m.file_name
		p.body = digest_quote(s, {text = text, files = m.kind == .File || m.attachment_count > 0})
	}
	data, err := json.marshal(p, allocator = context.temp_allocator)
	if err != nil || len(data) > webpush.PUSH_PAYLOAD_MOST {
		return
	}
	return data, true
}
