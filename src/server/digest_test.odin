package server

import "core:fmt"
import "core:strings"
import "core:testing"

import "common:proto"

// Tests of mailing accounts what they missed (digest.odin), on the
// Test_Server of auth_test.odin, with what's sent left in the email's
// jobs.

@(private = "file")
MINUTE :: i64(60 * 1000)

// mails_sent takes the mails the loop has asked to be sent.
@(private = "file")
mails_sent :: proc(ts: ^Test_Server) -> []Email_Job {
	e := &ts.s.email
	out := make([]Email_Job, len(e.jobs), context.temp_allocator)
	for job, i in e.jobs {
		out[i] = job
		out[i].to = strings.clone(job.to, context.temp_allocator)
		out[i].subject = strings.clone(job.subject, context.temp_allocator)
		out[i].body = strings.clone(job.body, context.temp_allocator)
		delete(job.to)
		delete(job.subject)
		delete(job.body)
	}
	clear(&e.jobs)
	return out
}

// away is when an account that has just left left, once that's in the
// past: what's posted from then on is posted after it.
@(private = "file")
away :: proc(acc: ^Account) -> i64 {
	for unix_ms() <= acc.last_seen {
	}
	return acc.last_seen
}

@(private = "file")
digest_set :: proc(t: ^testing.T, ts: ^Test_Server, u: ^Conn, value: string) -> proto.Status {
	buf: [proto.SETTING_MAX_SIZE]u8
	body := proto.encode_setting(buf[:], proto.SETTING_EMAIL_DIGEST, transmute([]u8)value)
	status, _ := ts_ask(t, ts, u, .Setting_Set, body)
	return status
}

@(test)
test_digests :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	// Email that's there without a thread: what it's asked to send waits
	// in its jobs.
	s.email.enabled = true
	s.email.config = {
		address        = "yap@example.org",
		imap           = "imaps://mx.example.org",
		smtp           = "smtps://mx.example.org",
		digest_minutes = 30,
	}
	s.name = "Test server"
	defer s.name = ""
	home := s.convs.home
	alice_acc := ts_account(t, &ts, "alice", "a password")
	ts_account(t, &ts, "bob", "a password")
	ts_account(t, &ts, "carol", "a password")
	testing.expect(t, account_set_email(&s.accounts, alice_acc, "alice@example.org"))
	alice := logged_in(t, &ts, "alice")
	bob := logged_in(t, &ts, "bob")
	carol := logged_in(t, &ts, "carol")
	tok := proto.mention_token(alice_acc.id)

	// The server says it sends them, and takes only what it knows.
	info, ok := proto.decode_server_info(server_info_body(s))
	testing.expect(t, ok && info.digests)
	testing.expect_value(t, digest_set(t, &ts, alice, "sometimes"), proto.Status.Invalid)
	testing.expect_value(t, alice_acc.digest, proto.Email_Digest.None)
	testing.expect_value(t, digest_set(t, &ts, alice, "all"), proto.Status.Invalid)
	testing.expect_value(t, digest_set(t, &ts, alice, "missed"), proto.Status.Ok)
	testing.expect_value(t, alice_acc.digest, proto.Email_Digest.Missed)

	ab: [4]u8
	status, answer := ts_ask(t, &ts, bob, .DM_Open, proto.encode_account_id(&ab, alice_acc.id))
	testing.expect_value(t, status, proto.Status.Ok)
	dm, _ := proto.decode_conv_id(answer)
	// Before she leaves: seen, if not read.
	post(t, &ts, bob, dm, "before", 1)

	// Here, nothing is mailed.
	start := unix_ms()
	digests_send(s, start + 120 * MINUTE)
	testing.expect_value(t, len(mails_sent(&ts)), 0)

	// Missed: every part, each message once.
	ts_disconnect(&ts, alice)
	left := away(alice_acc)
	post(t, &ts, bob, dm, fmt.tprintf("hello %s\nhow are you?", tok), 2)
	post(t, &ts, carol, home.id, fmt.tprintf("look, %s", tok), 3)
	post(t, &ts, carol, home.id, "chatter", 4)

	// Not away long enough yet.
	digests_send(s, left + 29 * MINUTE)
	testing.expect_value(t, len(mails_sent(&ts)), 0)

	digests_send(s, left + 30 * MINUTE)
	mails := mails_sent(&ts)
	testing.expect_value(t, len(mails), 1)
	if len(mails) == 1 {
		m := mails[0]
		testing.expect_value(t, m.to, "alice@example.org")
		testing.expect_value(t, m.subject, "Missed messages on Test server")
		testing.expect(
			t,
			strings.contains(
				m.body,
				"you've missed 1 direct message, 1 mention and 1 channel message on Test server:",
			),
			m.body,
		)
		testing.expect(t, strings.has_prefix(m.body, "Hi alice,\n\n"), m.body)
		testing.expect(t, strings.contains(m.body, "hello @alice how are you?"), m.body)
		testing.expect(t, strings.contains(m.body, "carol in #Lobby"), m.body)
		testing.expect(t, strings.contains(m.body, "look, @alice"), m.body)
		testing.expect(t, strings.contains(m.body, "In your channels"), m.body)
		testing.expect(t, strings.contains(m.body, "chatter"), m.body)
		testing.expect(t, !strings.contains(m.body, "before"), m.body)
		testing.expect_value(t, strings.count(m.body, "hello @alice"), 1)
		testing.expect_value(t, strings.count(m.body, "look, @alice"), 1)
	}

	// Nothing new: nothing more. Something new: not before the wait.
	digests_send(s, left + 40 * MINUTE)
	testing.expect_value(t, len(mails_sent(&ts)), 0)
	post(t, &ts, bob, dm, "still there?", 5)
	digests_send(s, left + 50 * MINUTE)
	testing.expect_value(t, len(mails_sent(&ts)), 0)
	digests_send(s, left + 60 * MINUTE)
	mails = mails_sent(&ts)
	testing.expect_value(t, len(mails), 1)
	if len(mails) == 1 {
		testing.expect_value(t, mails[0].subject, "Missed messages on Test server")
		testing.expect(
			t,
			strings.contains(mails[0].body, "you've missed 1 direct message on Test server:"),
			mails[0].body,
		)
		testing.expect(t, strings.contains(mails[0].body, "still there?"), mails[0].body)
		testing.expect(t, !strings.contains(mails[0].body, "hello"), mails[0].body)
	}
	testing.expect(t, alice_acc.digest_upto != 0)

	// Mentions: those, and direct messages, which count as them; not the
	// rest of a channel.
	alice = logged_in(t, &ts, "alice")
	testing.expect_value(t, digest_set(t, &ts, alice, "mentions"), proto.Status.Ok)
	ts_disconnect(&ts, alice)
	left = away(alice_acc)
	post(t, &ts, bob, dm, "a dm", 6)
	post(t, &ts, carol, home.id, "more chatter", 7)
	post(t, &ts, bob, home.id, fmt.tprintf("%s!", tok), 8)
	digests_send(s, left + 120 * MINUTE)
	mails = mails_sent(&ts)
	testing.expect_value(t, len(mails), 1)
	if len(mails) == 1 {
		testing.expect_value(t, mails[0].subject, "Missed messages on Test server")
		testing.expect(
			t,
			strings.contains(
				mails[0].body,
				"you've missed 1 direct message and 1 mention on Test server:",
			),
			mails[0].body,
		)
		testing.expect(t, strings.contains(mails[0].body, "a dm"), mails[0].body)
		testing.expect(t, !strings.contains(mails[0].body, "more chatter"), mails[0].body)
	}

	// Missed: what she'd have been told of. Everything where she hears
	// of everything, the DM too; in a channel that tells her only of
	// mentions, those.
	alice = logged_in(t, &ts, "alice")
	testing.expect_value(t, digest_set(t, &ts, alice, "missed"), proto.Status.Ok)
	nb: [proto.CONV_NOTIFY_SIZE]u8
	status, _ = ts_ask(
		t,
		&ts,
		alice,
		.Conv_Notify,
		proto.encode_conv_notify(&nb, home.id, .Mentions),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	ts_disconnect(&ts, alice)
	left = away(alice_acc)
	post(t, &ts, bob, dm, "another dm", 9)
	post(t, &ts, carol, home.id, "quiet chatter", 10)
	post(t, &ts, carol, home.id, fmt.tprintf("%s, quietly", tok), 11)
	digests_send(s, left + 200 * MINUTE)
	mails = mails_sent(&ts)
	testing.expect_value(t, len(mails), 1)
	if len(mails) == 1 {
		testing.expect_value(t, mails[0].subject, "Missed messages on Test server")
		testing.expect(
			t,
			strings.contains(
				mails[0].body,
				"you've missed 1 direct message and 1 mention on Test server:",
			),
			mails[0].body,
		)
		testing.expect(t, strings.contains(mails[0].body, "@alice, quietly"), mails[0].body)
		testing.expect(t, !strings.contains(mails[0].body, "quiet chatter"), mails[0].body)
	}

	// With the channel muted: only the DM.
	alice = logged_in(t, &ts, "alice")
	testing.expect_value(t, digest_set(t, &ts, alice, "missed"), proto.Status.Ok)
	status, _ = ts_ask(t, &ts, alice, .Conv_Notify, proto.encode_conv_notify(&nb, home.id, .None))
	testing.expect_value(t, status, proto.Status.Ok)
	ts_disconnect(&ts, alice)
	left = away(alice_acc)
	post(t, &ts, carol, home.id, fmt.tprintf("%s, muted", tok), 12)
	post(t, &ts, bob, dm, "dm while muted", 13)
	digests_send(s, left + 300 * MINUTE)
	mails = mails_sent(&ts)
	testing.expect_value(t, len(mails), 1)
	if len(mails) == 1 {
		testing.expect_value(t, mails[0].subject, "Missed messages on Test server")
		testing.expect(
			t,
			strings.contains(mails[0].body, "you've missed 1 direct message on Test server:"),
			mails[0].body,
		)
		testing.expect(t, !strings.contains(mails[0].body, "muted,"), mails[0].body)
	}

	// None: nothing at all.
	alice = logged_in(t, &ts, "alice")
	testing.expect_value(t, digest_set(t, &ts, alice, ""), proto.Status.Ok)
	testing.expect_value(t, alice_acc.digest, proto.Email_Digest.None)
	ts_disconnect(&ts, alice)
	left = away(alice_acc)
	post(t, &ts, bob, dm, "anyone?", 14)
	digests_send(s, left + 400 * MINUTE)
	testing.expect_value(t, len(mails_sent(&ts)), 0)
}

@(test)
test_digest_quote :: proc(t: ^testing.T) {
	ts: Test_Server
	ts_open(t, &ts)
	defer ts_close(&ts)
	s := &ts.s
	bob := ts_account(t, &ts, "bob", "a password")

	quote :: proc(s: ^Server, text: string, files := false) -> string {
		return digest_quote(s, {text = text, files = files})
	}
	testing.expect_value(t, quote(s, "", true), "(sent a file)")
	testing.expect_value(
		t,
		quote(s, fmt.tprintf("hi  %s\n\n<@everyone> <@999>", proto.mention_token(bob.id))),
		"hi @bob @everyone @somebody",
	)
	long := strings.repeat("ä", 150, context.temp_allocator) // 300 bytes
	cut := quote(s, long)
	testing.expect(t, strings.has_suffix(cut, "..."))
	testing.expect(t, len(cut) <= DIGEST_QUOTE_MOST + 3)
	testing.expect_value(t, len(cut) % 2, 1) // whole characters, then "..."

	testing.expect_value(t, digest_time(0), "1970-01-01 00:00 UTC")
}
