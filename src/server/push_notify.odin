package server

import "core:encoding/json"
import "core:fmt"

import "common:proto"

/*
What's pushed (push.odin), and to whom: what a desktop client would put
on the desktop (src/client/ui_notices.odin), for whoever isn't there to
see it.

  - A message in a DM, to the other one, and a message that mentions
    somebody, to each mentioned member: unless the conversation tells
    them nothing (Notify_Level.None). Not every message of a channel
    that tells of every message (Notify_Level.All, which is what a
    channel starts as): the desktop doesn't either, and a phone that
    buzzed for each would soon have push turned off.
  - Only to accounts that aren't here: no connection, or every one of
    them idle or out of sight (activity.odin; the web client says its
    page is hidden). Someone at the desktop has the desktop's notice.
  - To each of the account's subscriptions (push_subs.odin).

  - A call (calls.odin), to a callee that isn't here: "Alice is
    calling you", and once it's over, in its place, a missed call, or
    (quietly, and not to the device that did it) that it was answered
    or declined elsewhere. A push can't take a notification down (see
    misc/mobile, phase 3), but it can put another in its place.

A push carries JSON for the service worker (web/sw.js) to show:

	{"kind": "dm" | "mention" | "call", "server": <its name>,
	 "conv": <id>, "msg": <id>, "title": "Alice messaged you",
	 "body": <the text>, "tag": <its notification>, "quiet": <no sound>,
	 "ring": <a call ringing>}

The body is quoted as a digest quotes it (digest_quote), or empty for an
account that hides it (proto.SETTING_PUSH_TEXT). Pushes for the same
conversation share a Topic, so a push service holding several for a
phone that's off keeps only the newest, and the worker gives them one
notification (its tag) with a count.
*/

// How long a push service may keep a push for a phone that's off: what
// was missed a day ago is better read in the client.
PUSH_TTL :: 24 * 60 * 60

// What a push carries, as JSON.
Push_Payload :: struct {
	kind:   string,
	server: string,
	conv:   u32,
	msg:    u64,
	title:  string,
	body:   string,
	// The notification it is: a conversation's ("c<conv>"), or a
	// call's; whether it replaces another without a sound; and whether
	// it's a call ringing, which stays up until it's dealt with.
	tag:    string,
	quiet:  bool,
	ring:   bool,
}

// What's pushed of a call.
Push_Call :: enum {
	Ringing,
	Missed,
	Answered,
	Declined,
}

/*
push_message pushes a new message in `conv` to whoever it's for and
isn't here: the other one of a DM, and the members it mentions
(`mentioned`, as mentions_resolve gave them).
*/
push_message :: proc(s: ^Server, conv: ^Conv, m: proto.Message, mentioned: []proto.Account_Id) {
	if !s.push.enabled || m.kind == .System || .Deleted in m.flags {
		return
	}
	if conv.kind == .DM {
		push_member(s, conv, m, dm_other(conv, m.sender), "dm")
		return
	}
	for who in mentioned {
		push_member(s, conv, m, who, "mention")
	}
}

// push_away is whether an account isn't here to see a notice: no
// connection, or every one idle or out of sight.
push_away :: proc(acc: ^Account) -> bool {
	for u in acc.conns {
		if !u.idle && !u.hidden {
			return false
		}
	}
	return true
}

@(private = "file")
push_member :: proc(s: ^Server, conv: ^Conv, m: proto.Message, who: proto.Account_Id, kind: string) {
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
	payload, ok := push_payload(s, conv, m, kind, acc.push_hide)
	if !ok {
		return
	}
	push_to(s, who, payload, fmt.tprintf("c%d", conv.id), PUSH_TTL, .High)
}

// push_reaches is whether an account could be pushed something: the
// server pushes, and it has turned push on somewhere.
push_reaches :: proc(s: ^Server, acc: ^Account) -> bool {
	return s.push.enabled && len(push_subs_of(s, acc.id)) > 0
}

/*
push_call pushes a call to its callee: that it rings, if they aren't
here; or what came of one that was pushed, to every device but
`except`'s (which did it). Whether anything was pushed.
*/
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
	ttl, urgency := PUSH_TTL, Push_Urgency.Normal
	switch what {
	case .Ringing:
		p.title = fmt.tprintf("%s is calling you", name)
		p.body = "Answer it in yap."
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
		p.body = "Declined."
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

// push_to queues a payload for each of an account's subscriptions but
// `skip`'s device; how many.
@(private = "file")
push_to :: proc(
	s: ^Server,
	who: proto.Account_Id,
	payload: []u8,
	topic: string,
	ttl: int,
	urgency: Push_Urgency,
	skip: [proto.KEY_SIZE]u8 = {},
) -> (
	sent: int,
) {
	for sub in push_subs_of(s, who) {
		if skip != {} && sub.device == skip {
			continue
		}
		if push_send(
			&s.push,
			{
				sub = sub.id,
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

// push_payload is the JSON a push carries, in the temp allocator.
push_payload :: proc(
	s: ^Server,
	conv: ^Conv,
	m: proto.Message,
	kind: string,
	hide: bool,
) -> (
	payload: []u8,
	ok: bool,
) {
	sender := account_by_id(&s.accounts, m.sender)
	// Deleted accounts are kept, as tombstones; not having one shouldn't
	// happen.
	name := sender.display if sender != nil else "Somebody"
	p := Push_Payload {
		kind   = kind,
		server = s.name,
		conv   = u32(conv.id),
		msg    = u64(m.id),
		tag    = fmt.tprintf("c%d", conv.id),
	}
	if kind == "dm" {
		p.title = fmt.tprintf("%s messaged you", name)
	} else {
		p.title = fmt.tprintf("%s mentioned you in #%s", name, conv.name)
	}
	if !hide {
		text := m.text if m.kind == .Text else m.file_name
		p.body = digest_quote(
			s,
			{text = text, files = m.kind == .File || m.attachment_count > 0},
		)
	}
	data, err := json.marshal(p, allocator = context.temp_allocator)
	if err != nil || len(data) > PUSH_PAYLOAD_MOST {
		return
	}
	return data, true
}
