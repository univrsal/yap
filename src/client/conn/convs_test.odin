#+build !wasi
package conn

import "core:strings"
import "core:testing"

import "common:proto"

@(private = "file")
interrupts :: proc(c: ^Voice_Client, m: proto.Message) -> bool {
	i, _ := conv_new_message(c, m)
	return i
}

@(test)
test_unread_counting :: proc(t: ^testing.T) {
	c: Voice_Client
	defer convs_destroy(&c)
	c.auth.me = 1
	lobby, gaming := proto.Conv_Id(1), proto.Conv_Id(2)
	c.convs.convs[lobby] = {
		name = strings.clone("Lobby"),
		last = 10,
		read = 10,
	}
	c.convs.convs[gaming] = {
		name   = strings.clone("Gaming"),
		last   = 5,
		read   = 5,
		notify = .None,
	}

	// Someone else's message is unread, and may interrupt; in a muted
	// channel it's unread and may not.
	testing.expect(t, interrupts(&c, {id = 11, conv = lobby, sender = 2}))
	testing.expect(t, !interrupts(&c, {id = 12, conv = gaming, sender = 2}))
	testing.expect_value(t, c.convs.convs[lobby].unread, 1)
	testing.expect_value(t, c.convs.convs[gaming].unread, 1)

	// Our own reads everything up to it.
	testing.expect(t, interrupts(&c, {id = 13, conv = lobby, sender = 2}))
	testing.expect_value(t, c.convs.convs[lobby].unread, 2)
	testing.expect(t, !interrupts(&c, {id = 14, conv = lobby, sender = 1}))
	testing.expect_value(t, c.convs.convs[lobby].unread, 0)
	testing.expect_value(t, c.convs.convs[lobby].read, proto.Msg_Id(14))

	// Reading a conversation reads what's there, and what comes; the
	// server is to be told.
	conv_reading(&c, gaming)
	testing.expect_value(t, c.convs.convs[gaming].unread, 0)
	testing.expect_value(t, c.convs.marks[gaming].due, proto.Msg_Id(12))
	testing.expect(t, !interrupts(&c, {id = 15, conv = gaming, sender = 2}))
	testing.expect_value(t, c.convs.convs[gaming].unread, 0)
	testing.expect_value(t, c.convs.marks[gaming].due, proto.Msg_Id(15))
	conv_reading(&c, 0)
	testing.expect(t, !interrupts(&c, {id = 16, conv = gaming, sender = 2}))
	testing.expect_value(t, c.convs.convs[gaming].unread, 1)

	// What the server says of an older read than ours is behind: kept
	// out. A newer one (another device read further) is taken.
	buf: [proto.READ_CHANGED_SIZE]u8
	conv_event(
		&c,
		.Read_Changed,
		proto.encode_read_changed(&buf, {conv = gaming, read = 12, unread = 3}),
	)
	testing.expect_value(t, c.convs.convs[gaming].read, proto.Msg_Id(15))
	testing.expect_value(t, c.convs.convs[gaming].unread, 1)
	c.convs.marks[gaming] = {}
	conv_event(&c, .Read_Changed, proto.encode_read_changed(&buf, {conv = gaming, read = 16}))
	testing.expect_value(t, c.convs.convs[gaming].read, proto.Msg_Id(16))
	testing.expect_value(t, c.convs.convs[gaming].unread, 0)

	// Counting stops at the cap, and is shown as such.
	for i in 0 ..< 150 {
		conv_new_message(&c, {id = proto.Msg_Id(100 + i), conv = lobby, sender = 2})
	}
	testing.expect_value(t, c.convs.convs[lobby].unread, proto.UNREAD_CAP)
	testing.expect_value(t, unread_count(c.convs.convs[lobby].unread), "99+")
	testing.expect_value(t, unread_count(7), "7")
}

@(test)
test_mention_counting :: proc(t: ^testing.T) {
	c: Voice_Client
	defer convs_destroy(&c)
	c.auth.me = 1
	lobby, gaming, quiet := proto.Conv_Id(1), proto.Conv_Id(2), proto.Conv_Id(3)
	c.convs.convs[lobby] = {
		name   = strings.clone("Lobby"),
		last   = 10,
		read   = 10,
		notify = .Mentions,
	}
	c.convs.convs[gaming] = {
		name = strings.clone("Gaming"),
		last = 5,
		read = 5,
	}
	c.convs.convs[quiet] = {
		name   = strings.clone("Quiet"),
		last   = 5,
		read   = 5,
		notify = .None,
	}

	// "Mentions only": a plain message is counted and quiet; a mention
	// is counted twice over, and isn't.
	i, mention := conv_new_message(&c, {id = 11, conv = lobby, sender = 2, text = "hello"})
	testing.expect(t, !i && !mention)
	i, mention = conv_new_message(&c, {id = 12, conv = lobby, sender = 2, text = "hey <@1>"})
	testing.expect(t, i && mention)
	testing.expect_value(t, c.convs.convs[lobby].unread, 2)
	testing.expect_value(t, c.convs.convs[lobby].mentions, 1)
	i, mention = conv_new_message(&c, {id = 13, conv = lobby, sender = 2, text = "<@everyone>"})
	testing.expect(t, i && mention)
	_, mention = conv_new_message(&c, {id = 14, conv = lobby, sender = 2, text = "<@11> <@2>"})
	testing.expect(t, !mention, "somebody else's mention counted")
	testing.expect_value(t, c.convs.convs[lobby].mentions, 2)

	// Our own aren't, a muted one is counted and says nothing, and one
	// being read is read, but still a mention.
	_, mention = conv_new_message(&c, {id = 15, conv = gaming, sender = 1, text = "<@1>"})
	testing.expect(t, !mention)
	i, mention = conv_new_message(&c, {id = 16, conv = quiet, sender = 2, text = "<@1>"})
	testing.expect(t, !i && !mention)
	testing.expect_value(t, c.convs.convs[quiet].mentions, 1)
	i, mention = conv_new_message(&c, {id = 17, conv = quiet, sender = 2, text = "hi"})
	testing.expect(t, !i && !mention)
	conv_reading(&c, gaming)
	i, mention = conv_new_message(&c, {id = 18, conv = gaming, sender = 2, text = "<@1>"})
	testing.expect(t, !i && mention)
	testing.expect_value(t, c.convs.convs[gaming].mentions, 0)
	testing.expect_value(t, c.convs.convs[gaming].unread, 0)
	conv_reading(&c, quiet)
	_, mention = conv_new_message(&c, {id = 19, conv = quiet, sender = 2, text = "<@1>"})
	testing.expect(t, !mention, "a muted one being read")
}

// Reading a conversation while messages keep coming tells the server
// at most once every MARK_INTERVAL, and nothing more once it's told.
@(test)
test_mark_read_paced :: proc(t: ^testing.T) {
	c: Voice_Client
	defer convs_destroy(&c)
	defer stream_destroy(&c)
	defer delete(c.rpc.pending)
	c.auth.me = 1
	c.convs.synced = true
	c.has_current = true
	dm := proto.Conv_Id(5)
	c.convs.convs[dm] = {
		kind = .DM,
		a    = 1,
		b    = 2,
		last = 10,
		read = 10,
	}
	conv_reading(&c, dm)
	for i in 0 ..< 200 {
		conv_new_message(&c, {id = proto.Msg_Id(11 + i), conv = dm, sender = 2})
		convs_step(&c)
	}
	testing.expect_value(t, len(c.rpc.pending), 1)
	// The rest waits for the next one.
	testing.expect_value(t, c.convs.marks[dm].due, proto.Msg_Id(210))
}
