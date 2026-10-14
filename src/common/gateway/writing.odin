package gateway

import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:strconv"
import "core:time"

import "common:lite"
import "common:proto"

/*
Writing (docs/bot-api, phase 5): posting, editing, deleting, reacting,
pinning, reading, typing, DMs, subscribing, the profile and activity.

What answers with a message (posting, forwarding: 201) answers with it
as the server keeps it, asked for once it's posted: what the server made
of the text (mentions, links), and a repeated post's first message. What
changes a message (edit, delete, pin, reactions) answers 204: the
message as it is then comes as an event (phase 6), to whoever's
listening. What answers from the model (the profile, activity, a DM,
subscribing) waits for the events of the change first (after_events).

Bodies are JSON objects; a field left out is left as it is, and null,
where it means something, is "none".
*/

/*
POST /convs/{id}/messages {content, thread, nonce} -> 201 the message.
`content` as a person types it, markdown, @mentions and all; `thread`
the thread's first message, to reply in it; `nonce` anything (a string
or a number), the same for a post tried again, which then isn't posted
twice; `attachments` the ids of uploads (files.odin) to go with it, which
the text may then go without.
*/
@(private)
post_run :: proc(c: ^Conn, j: ^Job) {
	conv, ok := param_id(j, 0)
	if !ok {
		reply(j, bad_id(j.params[0]))
		return
	}
	obj, body_ok := body_object(j)
	if !body_ok {
		return
	}
	p := proto.Msg_Post {
		conv = proto.Conv_Id(conv),
		kind = .Text,
	}
	got: Field
	fields_ok: bool
	if p.text, got, fields_ok = field_string(j, obj, "content"); !fields_ok {
		return
	}
	if files, there := obj["attachments"]; there {
		list, is_array := files.(json.Array)
		if !is_array || len(list) > proto.MAX_ATTACHMENTS {
			reply(
				j,
				error_reply(
					400,
					"invalid",
					fmt.tprintf(
						"attachments is a list of at most %d uploads.",
						proto.MAX_ATTACHMENTS,
					),
				),
			)
			return
		}
		for v, i in list {
			id, id_ok := value_id(j, v, "an attachment")
			if !id_ok {
				return
			}
			if id == 0 {
				reply(j, error_reply(400, "invalid", "An attachment is an upload's id."))
				return
			}
			p.uploads[i] = id
		}
		p.attachment_count = len(list)
	}
	if (got != .Value || p.text == "") && p.attachment_count == 0 {
		reply(
			j,
			error_reply(
				400,
				"invalid",
				"content is the message's text (which files may go without).",
			),
		)
		return
	}
	if len(p.text) > proto.MAX_CHAT_SIZE {
		reply(
			j,
			error_reply(
				400,
				"invalid",
				fmt.tprintf("content is at most %d bytes.", proto.MAX_CHAT_SIZE),
			),
		)
		return
	}
	if id, id_ok := field_id(j, obj, "thread"); id_ok {
		p.thread_root = proto.Msg_Id(id)
	} else {
		return
	}
	nonce_ok: bool
	if p.nonce, nonce_ok = field_nonce(j, obj); !nonce_ok {
		return
	}
	j.scratch = {conv, u64(p.thread_root), 0}
	j.answer = posted
	buf: [proto.MSG_POST_MAX_SIZE]u8
	ask(c, j, .Msg_Post, proto.encode_msg_post(buf[:], p))
}

/*
POST /messages/{id}/forward {conv, thread, nonce} -> 201 the copy: the
message, one the account may read, copied to `conv` (proto/forward.odin).
*/
@(private)
forward_run :: proc(c: ^Conn, j: ^Job) {
	msg, ok := param_id(j, 0)
	if !ok {
		reply(j, bad_id(j.params[0]))
		return
	}
	obj, body_ok := body_object(j)
	if !body_ok {
		return
	}
	f := proto.Msg_Forward {
		msg = proto.Msg_Id(msg),
	}
	if id, id_ok := field_id(j, obj, "conv"); id_ok {
		f.conv = proto.Conv_Id(id)
	} else {
		return
	}
	if f.conv == 0 {
		reply(j, error_reply(400, "invalid", "conv is where to forward it to."))
		return
	}
	if id, id_ok := field_id(j, obj, "thread"); id_ok {
		f.thread_root = proto.Msg_Id(id)
	} else {
		return
	}
	nonce_ok: bool
	if f.nonce, nonce_ok = field_nonce(j, obj); !nonce_ok {
		return
	}
	j.scratch = {u64(f.conv), u64(f.thread_root), 0}
	j.answer = posted
	buf: [proto.MSG_FORWARD_SIZE]u8
	ask(c, j, .Msg_Forward, proto.encode_msg_forward(&buf, f))
}

/*
posted takes a post's (or forward's) answer, and asks for the message
it made: by then, as the server tells of a message as it answers its
post, the model has it too.
*/
@(private)
posted :: proc(c: ^Conn, j: ^Job, a: lite.Answer) {
	if a.status != .Ok {
		reply(j, status_reply(a.status))
		return
	}
	id, at, ok := proto.decode_msg_posted(a.body)
	if !ok {
		reply(j, status_reply(.Internal))
		return
	}
	j.answer = proc(c: ^Conn, j: ^Job, a: lite.Answer) {
		id := proto.Msg_Id(j.scratch[0])
		if a.status == .Ok {
			buf := make([]proto.Message, 1, context.temp_allocator)
			if _, msgs, ok := proto.decode_history_page(a.body, buf);
			   ok && len(msgs) == 1 && msgs[0].id == id {
				reply(j, json_reply(201, message_json(&c.model, &msgs[0])))
				return
			}
		}
		// Posted, but gone again already (deleted, purged): what's known.
		m := proto.Message {
			id     = id,
			conv   = proto.Conv_Id(j.scratch[1]),
			sender = c.model.self,
			time   = proto.Unix_Ms(j.scratch[2]),
		}
		reply(j, json_reply(201, message_json(&c.model, &m)))
	}
	h := proto.Msg_History {
		conv        = proto.Conv_Id(j.scratch[0]),
		thread_root = proto.Msg_Id(j.scratch[1]),
		anchor      = id,
		dir         = .Around,
		limit       = 1,
	}
	j.scratch = {u64(id), u64(h.conv), u64(at)}
	buf: [proto.MSG_HISTORY_SIZE]u8
	ask(c, j, .Msg_History, proto.encode_msg_history(&buf, h))
}

// PATCH /messages/{id} {content} -> 204: the account's own text message.
@(private)
edit_run :: proc(c: ^Conn, j: ^Job) {
	msg, ok := param_id(j, 0)
	if !ok {
		reply(j, bad_id(j.params[0]))
		return
	}
	obj, body_ok := body_object(j)
	if !body_ok {
		return
	}
	text, got, text_ok := field_string(j, obj, "content")
	if !text_ok {
		return
	}
	if got != .Value || text == "" {
		reply(j, error_reply(400, "invalid", "content is the message's new text."))
		return
	}
	if len(text) > proto.MAX_CHAT_SIZE {
		reply(
			j,
			error_reply(
				400,
				"invalid",
				fmt.tprintf("content is at most %d bytes.", proto.MAX_CHAT_SIZE),
			),
		)
		return
	}
	j.answer = answered_empty
	buf: [proto.MSG_EDIT_MAX_SIZE]u8
	ask(c, j, .Msg_Edit, proto.encode_msg_edit(&buf, proto.Msg_Id(msg), text))
}

// DELETE /messages/{id} -> 204: one's own, or any with Manage_Messages.
@(private)
delete_run :: proc(c: ^Conn, j: ^Job) {
	msg, ok := param_id(j, 0)
	if !ok {
		reply(j, bad_id(j.params[0]))
		return
	}
	j.answer = answered_empty
	buf: [proto.MSG_ID_SIZE]u8
	ask(c, j, .Msg_Delete, proto.encode_msg_id(&buf, proto.Msg_Id(msg)))
}

// PUT and DELETE /messages/{id}/pin -> 204.
@(private)
pin_run :: proc(c: ^Conn, j: ^Job) {
	pin(c, j, true)
}

@(private)
unpin_run :: proc(c: ^Conn, j: ^Job) {
	pin(c, j, false)
}

@(private)
pin :: proc(c: ^Conn, j: ^Job, on: bool) {
	msg, ok := param_id(j, 0)
	if !ok {
		reply(j, bad_id(j.params[0]))
		return
	}
	j.answer = answered_empty
	buf: [proto.MSG_PIN_SIZE]u8
	ask(c, j, .Msg_Pin, proto.encode_msg_pin(&buf, proto.Msg_Id(msg), on))
}

// PUT and DELETE /messages/{id}/reactions/{emoji} -> 204: the emoji
// URL-encoded, or :name: of one of the server's own.
@(private)
react_run :: proc(c: ^Conn, j: ^Job) {
	react(c, j, true)
}

@(private)
unreact_run :: proc(c: ^Conn, j: ^Job) {
	react(c, j, false)
}

@(private)
react :: proc(c: ^Conn, j: ^Job, on: bool) {
	msg, ok := param_id(j, 0)
	if !ok {
		reply(j, bad_id(j.params[0]))
		return
	}
	emoji := j.params[1]
	if len(emoji) > proto.MAX_REACTION_EMOJI {
		reply(j, error_reply(400, "invalid", "That's no emoji."))
		return
	}
	j.answer = answered_empty
	buf: [proto.MSG_REACT_MAX_SIZE]u8
	ask(c, j, .Msg_React, proto.encode_msg_react(&buf, proto.Msg_Id(msg), emoji, on))
}

/*
POST /convs/{id}/read {message} -> 204: read up to and with `message`,
or everything there is without one.
*/
@(private)
read_run :: proc(c: ^Conn, j: ^Job) {
	conv, ok := param_id(j, 0)
	if !ok {
		reply(j, bad_id(j.params[0]))
		return
	}
	obj, body_ok := body_object(j)
	if !body_ok {
		return
	}
	up_to: proto.Msg_Id
	if id, id_ok := field_id(j, obj, "message"); id_ok {
		up_to = proto.Msg_Id(id)
	} else {
		return
	}
	if up_to == 0 {
		known, in_it := c.model.convs[proto.Conv_Id(conv)]
		if !in_it {
			reply(j, error_reply(404, "not_found", "The account isn't in such a conversation."))
			return
		}
		if known.last == 0 {
			reply(j, empty_reply())
			return
		}
		up_to = known.last
	}
	j.answer = answered_empty
	buf: [proto.MARK_READ_SIZE]u8
	ask(c, j, .Mark_Read, proto.encode_mark_read(&buf, proto.Conv_Id(conv), up_to))
}

/*
POST /convs/{id}/typing {thread} -> 204: the others are told the account
is typing, for a few seconds. Unreliable, as a client's is: send it
again every few seconds while it lasts.
*/
@(private)
typing_run :: proc(c: ^Conn, j: ^Job) {
	conv, ok := param_id(j, 0)
	if !ok {
		reply(j, bad_id(j.params[0]))
		return
	}
	obj, body_ok := body_object(j)
	if !body_ok {
		return
	}
	thread: proto.Msg_Id
	if id, id_ok := field_id(j, obj, "thread"); id_ok {
		thread = proto.Msg_Id(id)
	} else {
		return
	}
	buf: [proto.TYPING_UP_SIZE]u8
	if !lite.send(&c.client, proto.encode_typing_up(&buf, proto.Conv_Id(conv), thread)) {
		reply(j, status_reply(.Reset))
		return
	}
	reply(j, empty_reply())
}

// PUT /convs/{id}/subscription -> the channel; DELETE -> 204.
@(private)
subscribe_run :: proc(c: ^Conn, j: ^Job) {
	subscribe(c, j, true)
}

@(private)
unsubscribe_run :: proc(c: ^Conn, j: ^Job) {
	subscribe(c, j, false)
}

@(private)
subscribe :: proc(c: ^Conn, j: ^Job, on: bool) {
	conv, ok := param_id(j, 0)
	if !ok {
		reply(j, bad_id(j.params[0]))
		return
	}
	j.scratch[0] = conv
	j.answer = proc(c: ^Conn, j: ^Job, a: lite.Answer) {
		if a.status != .Ok {
			reply(j, status_reply(a.status))
			return
		}
		if j.scratch[1] == 0 {
			reply(j, empty_reply())
			return
		}
		after_events(c, j, reply_conv)
	}
	j.scratch[1] = u64(on)
	buf: [proto.CONV_SUBSCRIBE_SIZE]u8
	ask(c, j, .Conv_Subscribe, proto.encode_conv_subscribe(&buf, proto.Conv_Id(conv), on))
}

// POST /dms {account} -> the DM with that account, made if need be.
@(private)
dm_run :: proc(c: ^Conn, j: ^Job) {
	obj, body_ok := body_object(j)
	if !body_ok {
		return
	}
	account, account_ok := field_id(j, obj, "account")
	if !account_ok {
		return
	}
	if account == 0 {
		reply(j, error_reply(400, "invalid", "account is whom to DM."))
		return
	}
	j.answer = proc(c: ^Conn, j: ^Job, a: lite.Answer) {
		if a.status != .Ok {
			reply(j, status_reply(a.status))
			return
		}
		conv, ok := proto.decode_conv_id(a.body)
		if !ok {
			reply(j, status_reply(.Internal))
			return
		}
		j.scratch[0] = u64(conv)
		after_events(c, j, reply_conv)
	}
	buf: [4]u8
	ask(c, j, .DM_Open, proto.encode_account_id(&buf, proto.Account_Id(account)))
}

// reply_conv answers with the conversation j.scratch[0], as the model
// has it.
@(private)
reply_conv :: proc(c: ^Conn, j: ^Job) {
	conv, in_it := &c.model.convs[proto.Conv_Id(j.scratch[0])]
	if !in_it {
		reply(j, json_reply(200, struct {
				id: string,
			}{id_string(j.scratch[0])}))
		return
	}
	reply(j, json_reply(200, conv_json(&c.model, &conv.conv)))
}

/*
PATCH /me {display, status, status_until} -> the account as it is then.
`status` null or "" clears it; `status_until` (ISO 8601, or null for
never) is when it clears itself.
*/
@(private)
profile_run :: proc(c: ^Conn, j: ^Job) {
	obj, body_ok := body_object(j)
	if !body_ok {
		return
	}
	p: proto.Profile_Set
	display, display_got, display_ok := field_string(j, obj, "display")
	if !display_ok {
		return
	}
	if display_got == .Value {
		p.mask |= proto.PROFILE_DISPLAY
		p.display = display
	}
	status, status_got, status_ok := field_string(j, obj, "status")
	if !status_ok {
		return
	}
	until, until_got, until_ok := field_string(j, obj, "status_until")
	if !until_ok {
		return
	}
	if status_got != .Absent || until_got != .Absent {
		p.mask |= proto.PROFILE_STATUS
		p.status = status
		if status_got == .Absent {
			p.status = c.model.accounts[c.model.self].status // the one there is
		}
		if until_got == .Value {
			t, consumed := time.rfc3339_to_time_utc(until)
			if consumed == 0 {
				reply(j, error_reply(400, "invalid", "status_until is a time in ISO 8601."))
				return
			}
			p.status_until = proto.Unix_Ms(max(time.to_unix_nanoseconds(t) / 1e6, 1))
		}
	}
	if p.mask == 0 {
		reply(j, error_reply(400, "invalid", "Nothing to change: display, status, status_until."))
		return
	}
	if _, has := obj["avatar"]; has {
		reply(
			j,
			error_reply(
				400,
				"invalid",
				"A picture is set with PUT /me/avatar, and taken away with DELETE.",
			),
		)
		return
	}
	j.answer = answered_me
	buf: [256 + proto.MAX_NAME_SIZE + proto.MAX_STATUS_SIZE]u8
	body := proto.encode_profile_set(buf[:], p)
	if body == nil {
		reply(j, error_reply(400, "invalid", "That's too long."))
		return
	}
	ask(c, j, .Profile_Set, body)
}

// PUT /me/activity {activity} -> the account as it is then: online,
// away, busy or offline (appear offline).
@(private)
activity_run :: proc(c: ^Conn, j: ^Job) {
	obj, body_ok := body_object(j)
	if !body_ok {
		return
	}
	name, got, name_ok := field_string(j, obj, "activity")
	if !name_ok {
		return
	}
	activity: proto.Activity
	known := false
	for a in proto.Activity {
		if got == .Value && enum_name(a) == name {
			activity, known = a, true
		}
	}
	if !known {
		reply(j, error_reply(400, "invalid", "activity is online, away, busy or offline."))
		return
	}
	j.answer = answered_me
	buf: [proto.ACTIVITY_SET_SIZE]u8
	ask(c, j, .Activity_Set, proto.encode_activity(&buf, activity))
}

// answered_me answers with the account once the change's events are in.
@(private)
answered_me :: proc(c: ^Conn, j: ^Job, a: lite.Answer) {
	if a.status != .Ok {
		reply(j, status_reply(a.status))
		return
	}
	after_events(c, j, proc(c: ^Conn, j: ^Job) {
		reply(j, json_reply(200, me_json(&c.model)))
	})
}

// answered_empty is an answer with nothing to say: 204, or the error.
@(private)
answered_empty :: proc(c: ^Conn, j: ^Job, a: lite.Answer) {
	reply(j, status_reply(a.status))
}

// What a body's field was.
@(private)
Field :: enum {
	Absent,
	Null,
	Value,
}

/*
body_object is the Job's body as a JSON object, in the temp allocator;
an empty body is an empty object. If it isn't one, the Job is answered,
and it's false.
*/
@(private)
body_object :: proc(j: ^Job) -> (obj: json.Object, ok: bool) {
	if len(j.body) == 0 {
		return {}, true
	}
	v, err := json.parse(j.body, allocator = context.temp_allocator)
	if err == nil {
		if o, is_object := v.(json.Object); is_object {
			return o, true
		}
	}
	reply(j, error_reply(400, "invalid", "The body is a JSON object."))
	return
}

// field_string is a string field; false (and the Job answered) if it's
// something else.
@(private)
field_string :: proc(j: ^Job, obj: json.Object, key: string) -> (s: string, got: Field, ok: bool) {
	v, there := obj[key]
	if !there {
		return "", .Absent, true
	}
	switch x in v {
	case json.Null:
		return "", .Null, true
	case json.String:
		return x, .Value, true
	case json.Integer, json.Float, json.Boolean, json.Array, json.Object:
	}
	reply(j, error_reply(400, "invalid", fmt.tprintf("%s is a string.", key)))
	return
}

// field_id is an id field (a string, or a number), 0 if absent or null;
// false (and the Job answered) if it isn't one.
@(private)
field_id :: proc(j: ^Job, obj: json.Object, key: string) -> (id: u64, ok: bool) {
	v, there := obj[key]
	if !there {
		return 0, true
	}
	return value_id(j, v, key)
}

// value_id is a JSON value as an id: as field_id, `what` saying what it
// is if it isn't one.
@(private)
value_id :: proc(j: ^Job, v: json.Value, what: string) -> (id: u64, ok: bool) {
	switch x in v {
	case json.Null:
		return 0, true
	case json.String:
		if n, parsed := strconv.parse_u64(x, 10); parsed && n != 0 {
			return n, true
		}
	case json.Float:
		if x >= 1 && x < 1 << 53 && x == f64(u64(x)) {
			return u64(x), true
		}
	case json.Integer:
		if x > 0 {
			return u64(x), true
		}
	case json.Boolean, json.Array, json.Object:
	}
	reply(j, error_reply(400, "invalid", fmt.tprintf("%s is an id.", what)))
	return
}

/*
field_nonce is a post's nonce: the protocol's u64 from whatever the bot
gave (a string or a number), hashed, so the same one is the same post;
without one, one at random.
*/
@(private)
field_nonce :: proc(j: ^Job, obj: json.Object) -> (nonce: u64, ok: bool) {
	v, there := obj["nonce"]
	given: string
	if there {
		switch x in v {
		case json.Null:
		case json.String:
			given = x
		case json.Integer:
			given = fmt.tprint(x)
		case json.Float:
			given = fmt.tprint(x)
		case json.Boolean, json.Array, json.Object:
			reply(j, error_reply(400, "invalid", "nonce is a string or a number."))
			return
		}
	}
	if given != "" {
		nonce = hash.fnv64a(transmute([]u8)given)
	} else {
		crypto.rand_bytes(([^]u8)(&nonce)[:size_of(nonce)])
	}
	return max(nonce, 1), true
}
