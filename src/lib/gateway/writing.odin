package gateway

import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:strconv"
import "core:time"

import "common:proto"
import "lib:lite"

// Writing (docs/bot-api, phase 5): posting, editing, deleting, reacting,
// pinning, reading, typing, DMs, subscribing, the profile and activity.
//
// Endpoints that create a message (posting and forwarding, status 201) reply
// with the message as the server stores it. The gateway requests it after the
// post, so the reply shows how the server processed the text (mentions,
// links) and, for a repeated post, the original message. Endpoints that
// change a message (edit, delete, pin, reactions) reply with 204. The changed
// message is delivered as an event (phase 6) to whoever is listening.
// Endpoints that reply from the model (the profile, activity, a DM,
// subscribing) first wait for the events of the change (after_events).
//
// Bodies are JSON objects. A field that is left out stays unchanged, and null
// means "none" where that makes sense.

// POST /convs/{id}/messages {content, thread, nonce} -> 201 the message.
// `content` is the text as a person would type it, including markdown and
// @mentions. `thread` is the first message of a thread, to reply in it.
// `nonce` can be anything (a string or a number) and must be the same when a
// post is retried, so that it isn't posted twice. `attachments` are the ids of
// uploads (files.odin) to send along with it, in which case the text may be
// empty.
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
						"attachments must be a list of at most %d uploads.",
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
				reply(
					j,
					error_reply(400, "invalid", "Each attachment must be the id of an upload."),
				)
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
				"content is required and contains the message's text, unless the message has attachments.",
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
				fmt.tprintf("content can be at most %d bytes long.", proto.MAX_CHAT_SIZE),
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

// POST /messages/{id}/forward {conv, thread, nonce} -> 201 the copy. The
// message must be one that the account may read, and it is copied to `conv`
// (proto/forward.odin).
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
		reply(
			j,
			error_reply(
				400,
				"invalid",
				"conv is required and is the conversation to forward the message to.",
			),
		)
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

// posted handles the answer to a post (or forward) and requests the message
// that it created. The server announces a message before it answers the post,
// so the model already has the message by then.
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
		// The message was posted but is already gone (deleted or purged), so
		// reply with what is known.
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

// PATCH /messages/{id} {content} -> 204 edits one of the account's own text
// messages.
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
		reply(
			j,
			error_reply(
				400,
				"invalid",
				"content is required and contains the message's new text.",
			),
		)
		return
	}
	if len(text) > proto.MAX_CHAT_SIZE {
		reply(
			j,
			error_reply(
				400,
				"invalid",
				fmt.tprintf("content can be at most %d bytes long.", proto.MAX_CHAT_SIZE),
			),
		)
		return
	}
	j.answer = answered_empty
	buf: [proto.MSG_EDIT_MAX_SIZE]u8
	ask(c, j, .Msg_Edit, proto.encode_msg_edit(&buf, proto.Msg_Id(msg), text))
}

// DELETE /messages/{id} -> 204 deletes a message. The account can delete its
// own messages, or any message with the Manage_Messages permission.
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

// PUT and DELETE /messages/{id}/reactions/{emoji} -> 204 add or remove a
// reaction. The emoji is the URL-encoded character, or :name: for one of the
// server's own emoji.
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
		reply(j, error_reply(400, "invalid", "The emoji is too long to be valid."))
		return
	}
	j.answer = answered_empty
	buf: [proto.MSG_REACT_MAX_SIZE]u8
	ask(c, j, .Msg_React, proto.encode_msg_react(&buf, proto.Msg_Id(msg), emoji, on))
}

// POST /convs/{id}/read {message} -> 204 marks the conversation as read up to
// and including `message`, or everything in it if no message is given.
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
			reply(
				j,
				error_reply(
					404,
					"not_found",
					"The account is not in a conversation with this id.",
				),
			)
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

// POST /convs/{id}/typing {thread} -> 204 tells the others that the account is
// typing, for a few seconds. Like a client's typing notification it is
// unreliable, so send it again every few seconds while typing continues.
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

// POST /dms {account} -> the DM with that account, which is created if it
// doesn't exist yet.
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
		reply(
			j,
			error_reply(
				400,
				"invalid",
				"account is required and is the id of the account to send a DM to.",
			),
		)
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

// POST /groups {accounts} -> the group of the account and those accounts (2
// to proto.MAX_GROUP_MEMBERS - 1 of them), which is created if it doesn't exist
// yet. Bots can't be in groups, so for a bot's token this is always 403.
@(private)
group_run :: proc(c: ^Conn, j: ^Job) {
	obj, body_ok := body_object(j)
	if !body_ok {
		return
	}
	invalid :: proc(j: ^Job) {
		reply(
			j,
			error_reply(
				400,
				"invalid",
				fmt.tprintf(
					"accounts is required and is a list of 2 to %d ids of the others in the group.",
					proto.MAX_GROUP_MEMBERS - 1,
				),
			),
		)
	}
	list, is_array := obj["accounts"].(json.Array)
	if !is_array || len(list) < 2 || len(list) > proto.MAX_GROUP_MEMBERS - 1 {
		invalid(j)
		return
	}
	others: [proto.MAX_GROUP_MEMBERS - 1]proto.Account_Id
	for v, i in list {
		id, id_ok := value_id(j, v, "an account")
		if !id_ok {
			return
		}
		if id == 0 || id > u64(max(u32)) {
			invalid(j)
			return
		}
		others[i] = proto.Account_Id(id)
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
	buf: [proto.GROUP_OPEN_MAX_SIZE]u8
	body := proto.encode_group_open(&buf, others[:len(list)])
	if body == nil {
		invalid(j)
		return
	}
	ask(c, j, .Group_Open, body)
}

// reply_conv replies with the conversation j.scratch[0] as the model has
// it.
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

// PATCH /me {display, status, status_until} -> the account after the change.
// A `status` of null or "" clears the status. `status_until` (ISO 8601, or
// null for never) is when the status clears itself.
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
			p.status = c.model.accounts[c.model.self].status // keep the current status
		}
		if until_got == .Value {
			t, consumed := time.rfc3339_to_time_utc(until)
			if consumed == 0 {
				reply(
					j,
					error_reply(400, "invalid", "status_until must be a time in ISO 8601 format."),
				)
				return
			}
			p.status_until = proto.Unix_Ms(max(time.to_unix_nanoseconds(t) / 1e6, 1))
		}
	}
	if p.mask == 0 {
		reply(
			j,
			error_reply(
				400,
				"invalid",
				"There is nothing to change. Send at least one of display, status or status_until.",
			),
		)
		return
	}
	if _, has := obj["avatar"]; has {
		reply(
			j,
			error_reply(
				400,
				"invalid",
				"The avatar can't be changed here. Set it with PUT /me/avatar and remove it with DELETE /me/avatar.",
			),
		)
		return
	}
	j.answer = answered_me
	buf: [256 + proto.MAX_NAME_SIZE + proto.MAX_STATUS_SIZE]u8
	body := proto.encode_profile_set(buf[:], p)
	if body == nil {
		reply(j, error_reply(400, "invalid", "The display name or status is too long."))
		return
	}
	ask(c, j, .Profile_Set, body)
}

// PUT /me/activity {activity} -> the account after the change. The activity
// is online, away, busy or offline (appear offline).
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
		reply(
			j,
			error_reply(400, "invalid", "activity must be one of online, away, busy or offline."),
		)
		return
	}
	j.answer = answered_me
	buf: [proto.ACTIVITY_SET_SIZE]u8
	ask(c, j, .Activity_Set, proto.encode_activity(&buf, activity))
}

// answered_me replies with the account once the events of the change have
// arrived.
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

// answered_empty replies with 204, or with the error if the request failed.
@(private)
answered_empty :: proc(c: ^Conn, j: ^Job, a: lite.Answer) {
	reply(j, status_reply(a.status))
}

// Whether a field of a body was absent, null or had a value.
@(private)
Field :: enum {
	Absent,
	Null,
	Value,
}

// body_object returns the Job's body as a JSON object, allocated with the
// temp allocator. An empty body is an empty object. If the body isn't an
// object, the Job is answered with an error and ok is false.
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
	reply(j, error_reply(400, "invalid", "The request body must be a JSON object."))
	return
}

// field_string returns a string field. ok is false, and the Job has been
// answered, if the field is something else.
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
	reply(j, error_reply(400, "invalid", fmt.tprintf("%s must be a string.", key)))
	return
}

// field_id returns an id field (a string or a number), or 0 if it is absent
// or null. ok is false, and the Job has been answered, if it isn't an id.
@(private)
field_id :: proc(j: ^Job, obj: json.Object, key: string) -> (id: u64, ok: bool) {
	v, there := obj[key]
	if !there {
		return 0, true
	}
	return value_id(j, v, key)
}

// value_id converts a JSON value to an id, like field_id does. `what` names
// the value in the error message if it isn't an id.
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
	reply(j, error_reply(400, "invalid", fmt.tprintf("%s must be an id.", what)))
	return
}

// field_nonce returns a post's nonce. It hashes whatever the bot gave (a
// string or a number) into the protocol's u64, so the same input always
// produces the same nonce and thus the same post. Without input, the nonce is
// random.
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
			reply(j, error_reply(400, "invalid", "nonce must be a string or a number."))
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
