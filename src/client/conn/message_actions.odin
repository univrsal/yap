package conn

import log "common:wlog"
import "core:fmt"
import "core:strings"

import "client:richtext"
import "common:proto"

// What can be done to a message that is there: react, forward, edit, delete, pin.

// Ask who reacted to a message with an emoji, for the UI to show
// (View.reactors).
Reactors_Command :: struct {
	id:    proto.Msg_Id,
	emoji: string, // owned by the command
}

// reactors_fetch asks who reacted with `emoji`. The previous request is
// forgotten, and its answer is ignored if it still arrives.
reactors_fetch :: proc(c: ^Server_Conn, id: proto.Msg_Id, emoji: string) {
	mc := &c.msgs
	delete(mc.reactors_emoji)
	mc.reactors_id, mc.reactors_emoji = id, strings.clone(emoji)
	buf: [proto.REACTORS_GET_MAX_SIZE]u8
	body := proto.encode_reactors_get(&buf, id, emoji)
	if body == nil {
		return
	}
	request(
		c,
		.Reactors_Get,
		body,
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			mc := &c.msgs
			if status != .Ok || proto.Msg_Id(tag) != mc.reactors_id {
				return
			}
			buf: [proto.MAX_REACTORS]proto.Account_Id
			total, accounts, ok := proto.decode_reactors(body, &buf)
			if !ok {
				return
			}
			publish_reactors(c, mc.reactors_id, mc.reactors_emoji, total, accounts)
		},
		u64(id),
	)
}

// React with an emoji to a message, or (`on` false) take it back.
React_Command :: struct {
	id:    proto.Msg_Id,
	emoji: string, // owned by the command
	on:    bool,
	typed: bool, // the emoji is a :shortcode: as typed, as in Chat_Command
}

msg_react :: proc(c: ^Server_Conn, cmd: React_Command) {
	emoji := richtext.emoji_encode(cmd.emoji, c.emoji.names[:]) if cmd.typed else cmd.emoji
	buf: [proto.MSG_REACT_MAX_SIZE]u8
	body := proto.encode_msg_react(&buf, cmd.id, emoji, cmd.on)
	if body == nil {
		return
	}
	request(
		c,
		.Msg_React,
		body,
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			#partial switch status {
			case .Ok, .Reset:
			case .Too_Large:
				notify(
					c,
					false,
					fmt.tprintf(
						"A message can't have more than %d different reactions.",
						proto.MAX_REACTIONS,
					),
				)
			case .Invalid:
				notify(c, false, "That emoji can't be used as a reaction here.")
			case:
				notify(
					c,
					false,
					fmt.tprintf("The server failed to add the reaction (%v).", status),
				)
			}
		},
	)
}

// Forward a message (Msg_Forward) to a conversation. Headless, the
// destination is a channel given by name.
Forward_Command :: struct {
	msg:  proto.Msg_Id,
	conv: proto.Conv_Id,
	name: string, // owned by the command
}

msg_forward :: proc(c: ^Server_Conn, cmd: Forward_Command) {
	conv := cmd.conv if cmd.conv != 0 else conv_by_name(c, cmd.name)
	if conv == 0 {
		log.warnf("you aren't a member of a channel called %q", cmd.name)
		return
	}
	buf: [proto.MSG_FORWARD_SIZE]u8
	body := proto.encode_msg_forward(&buf, {conv = conv, nonce = new_nonce(), msg = cmd.msg})
	request(
		c,
		.Msg_Forward,
		body,
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			#partial switch status {
			case .Ok:
				notify(c, true, "Forwarded.")
			case .Reset:
			case .Not_Found:
				notify(
					c,
					false,
					"The message to forward or the destination conversation no longer exists.",
				)
			case .Invalid:
				notify(c, false, "That message can't be forwarded.")
			case .Denied:
				notify(c, false, "You don't have permission to post in that conversation.")
			case:
				notify(
					c,
					false,
					fmt.tprintf("The server failed to forward the message (%v).", status),
				)
			}
		},
	)
}

// Change a message of ours (Msg_Edit), delete one (Msg_Delete), or pin or
// unpin one (Msg_Pin).
Edit_Command :: struct {
	id:    proto.Msg_Id,
	text:  string, // owned by the command
	typed: bool, // as in Chat_Command
}

Delete_Command :: struct {
	id: proto.Msg_Id,
}

Pin_Command :: struct {
	id: proto.Msg_Id,
	on: bool,
}

// Fetch the pinned messages of a conversation (0 means the one we are looking
// at) for the UI's pins window. They are kept up to date until the pins of
// another conversation are requested.
Pins_Command :: struct {
	conv: proto.Conv_Id,
}

// Move the window of the conversation we are looking at to message `id`.
Jump_Command :: struct {
	id: proto.Msg_Id,
}

msg_edit :: proc(c: ^Server_Conn, id: proto.Msg_Id, raw: string) {
	buf: [proto.MAX_CHAT_SIZE]u8
	text := proto.sanitize_message(raw, buf[:])
	if text == "" {
		return
	}
	body_buf: [proto.MSG_EDIT_MAX_SIZE]u8
	request(c, .Msg_Edit, proto.encode_msg_edit(&body_buf, id, text), change_done, u64(id))
}

msg_delete :: proc(c: ^Server_Conn, id: proto.Msg_Id) {
	buf: [proto.MSG_ID_SIZE]u8
	request(c, .Msg_Delete, proto.encode_msg_id(&buf, id), change_done, u64(id))
}

msg_pin :: proc(c: ^Server_Conn, id: proto.Msg_Id, on: bool) {
	buf: [proto.MSG_PIN_SIZE]u8
	request(c, .Msg_Pin, proto.encode_msg_pin(&buf, id, on), change_done, u64(id))
}

// change_done handles the answer to a change of a message. A change that
// succeeded arrives separately, as Msg_Changed.
@(private = "file")
change_done :: proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
	#partial switch status {
	case .Ok, .Reset:
	case .Denied:
		notify(c, false, "You aren't allowed to modify this message.")
	case .Too_Large:
		notify(
			c,
			false,
			fmt.tprintf("A conversation can't have more than %d pinned messages.", proto.MAX_PINS),
		)
	case .Not_Found:
		notify(c, false, "That message no longer exists.")
	case:
		notify(c, false, fmt.tprintf("The server failed to change the message (%v).", status))
	}
}

// pins_fetch asks for a conversation's pinned messages, which are passed to the
// UI (or, headless, written to the log).
pins_fetch :: proc(c: ^Server_Conn, conv: proto.Conv_Id) {
	if conv == 0 {
		return
	}
	c.msgs.pins_conv = conv
	publish_pins_loading(c, conv)
	buf: [4]u8
	request(
		c,
		.Pins_Get,
		proto.encode_conv_id(&buf, conv),
		proc(c: ^Server_Conn, status: proto.Status, body: []u8, tag: u64) {
			conv := proto.Conv_Id(tag)
			if c.msgs.pins_conv != conv || status != .Ok {
				return
			}
			buf: [proto.MAX_PINS]proto.Message
			pins, ok := proto.decode_message_list(body, buf[:])
			if !ok {
				return
			}
			publish_pins(c, conv, pins)
			report_pins(c, conv, pins)
		},
		u64(conv),
	)
}
