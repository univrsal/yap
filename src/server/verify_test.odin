package server

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

import "common:proto"
import "mail"

// Tests of verifying email addresses by mail (verify.odin), using the
// Test_Server from harness_test.odin. mail.Message is put into the server's queue
// directly.

@(test)
test_auth_passed :: proc(t: ^testing.T) {
	MX :: "mx.example.org"
	check :: proc(
		t: ^testing.T,
		want: bool,
		from: string,
		results: ..string,
		loc := #caller_location,
	) {
		testing.expectf(
			t,
			auth_passed(results, MX, from) == want,
			"%v for %q",
			results,
			from,
			loc = loc,
		)
	}
	check(t, true, "a@b.com", "mx.example.org; dmarc=pass (p=none) header.from=b.com")
	check(t, true, "a@b.com", "MX.example.org 1; dkim=pass header.d=b.com header.s=x")
	check(t, true, "a@mail.b.com", "mx.example.org; dkim=pass header.d=b.com") // relaxed
	check(t, true, "a@b.com", "mx.example.org; dkim=pass header.i=@b.com")
	check(t, true, "a@b.com", "mx.example.org; spf=pass smtp.mailfrom=bounce@b.com")
	check(t, true, "a@b.com", "mx.example.org;\n\tspf=pass (sender is ok) smtp.mailfrom=\"b.com\"")
	check(
		t,
		true,
		"a@b.com",
		"mx.example.org; dkim=fail header.d=b.com; spf=pass smtp.mailfrom=b.com",
	)

	check(t, false, "a@b.com", "mx.example.org; dkim=fail header.d=b.com")
	check(t, false, "a@b.com", "mx.example.org; dkim=pass header.d=evil.com")
	check(t, false, "a@b.com", "mx.example.org; dkim=pass header.d=xb.com") // not a parent
	check(t, false, "a@b.com", "mx.example.org; dkim=pass header.d=mail.b.com") // a child
	check(t, false, "a@b.com", "mx.example.org; spf=softfail smtp.mailfrom=b.com")
	check(t, false, "a@b.com", "mx.example.org; none")
	check(t, false, "a@b.com", "other.example; dmarc=pass header.from=b.com")
	// Headers below the topmost one may have been written by the sender,
	// so a pass from the trusted host further down doesn't count.
	check(
		t,
		false,
		"a@b.com",
		"other.example; spf=fail smtp.mailfrom=b.com",
		"mx.example.org; dmarc=pass header.from=b.com",
	)
	// A "pass" inside a comment doesn't count.
	check(t, false, "a@b.com", "mx.example.org; dkim=none (dkim=pass header.d=b.com)")
	check(t, false, "a@b.com")
	testing.expect(
		t,
		!auth_passed({"mx.example.org; dmarc=pass header.from=b.com"}, "", "a@b.com"),
	)

	testing.expect(t, subject_has_code("Verify: abcd2345 please", "ABCD2345"))
	testing.expect(t, !subject_has_code("Verify", "ABCD2345"))
	testing.expect(t, !subject_has_code("anything", ""))
}

@(private = "file")
GOOD_AUTH :: "mx.example.org; dkim=pass header.d=example.com; spf=pass smtp.mailfrom=example.com"

// mail_in queues an incoming mail the same way the email thread would.
@(private = "file")
mail_in :: proc(ts: ^Test_Server, uid: u32, from, subject: string, auth := GOOD_AUTH) {
	header := fmt.tprintf(
		"Authentication-Results: %s\r\nFrom: <%s>\r\nSubject: %s\r\n\r\n",
		auth,
		from,
		subject,
	)
	if auth == "" {
		header = fmt.tprintf("From: <%s>\r\nSubject: %s\r\n\r\n", from, subject)
	}
	e := &ts.s.email
	sync.guard(&e.mutex)
	append(&e.inbox, mail.parse(uid, header))
}

// deletes_asked returns how many mails the loop has asked to be deleted, and
// clears those requests.
@(private = "file")
deletes_asked :: proc(ts: ^Test_Server) -> int {
	e := &ts.s.email
	n := len(e.jobs)
	clear(&e.jobs)
	return n
}

@(private = "file")
verifying_server :: proc(t: ^testing.T, ts: ^Test_Server) {
	ts_open(t, ts)
	ts.s.registration = {
		open             = true,
		verify_email     = true,
		unverified_hours = 48,
	}
	// mail.Mailer is enabled, but without its thread: incoming mail is put in its
	// queue by hand, and the jobs it's given just wait in its job list.
	ts.s.email.enabled = true
	ts.s.email.config = {
		address            = "yap@example.org",
		imap               = "imaps://mx.example.org",
		check_auth_results = true,
		trusted_auth_host  = "mx.example.org",
	}
}

@(test)
test_verify :: proc(t: ^testing.T) {
	ts: Test_Server
	verifying_server(t, &ts)
	defer ts_close(&ts)
	s := &ts.s

	u := ts_connect(&ts)
	buf: [proto.REGISTER_BODY_MAX]u8
	status, _ := ts_ask(
		t,
		&ts,
		u,
		.Register,
		proto.encode_register(
			buf[:],
			{username = "carol", password = "carol's password", email = "Carol@Example.com"},
		),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	acc := u.account
	if acc == nil {
		return
	}
	// The account is registered but unverified: it's hidden from everyone,
	// told how to verify, and can't do anything else.
	testing.expect(t, .Unverified in acc.flags)
	testing.expect(t, u.key in s.waiting && u.key not_in s.conns)
	testing.expect_value(t, len(acc.verify_code), proto.VERIFY_CODE_SIZE)
	testing.expect(t, acc.verify_expires > unix_ms() + 47 * 60 * 60 * 1000)
	self, told := has_event(ts_events(t, &ts, u), .Self)
	testing.expect(t, told)
	code, by := proto.self_verify(self.body)
	testing.expect_value(t, code, acc.verify_code)
	testing.expect_value(t, i64(by), acc.verify_expires)
	_, _, flags, _ := proto.decode_self(self.body)
	testing.expect(t, .Unverified in flags)
	status, _ = ts_ask(t, &ts, u, .Conv_Browse)
	testing.expect_value(t, status, proto.Status.Denied)
	status, _ = ts_ask(t, &ts, u, .Server_Info)
	testing.expect_value(t, status, proto.Status.Ok)

	// Mails that don't verify the account are still deleted.
	subject := fmt.tprintf("verify %s", acc.verify_code)
	mail_in(&ts, 1, "someone@example.com", subject) // not hers
	mail_in(&ts, 2, "carol@example.com", "hello") // no code
	mail_in(&ts, 3, "carol@example.com", subject, auth = "") // no proof it's from that address
	mail_in(
		&ts,
		4,
		"carol@example.com",
		subject,
		auth = "mx.example.org; dkim=fail header.d=example.com",
	)
	mail_in(
		&ts,
		5,
		"carol@example.com",
		subject,
		auth = "evil.example; dmarc=pass header.from=example.com",
	)
	verify_sync(s)
	testing.expect(t, .Unverified in acc.flags)
	testing.expect_value(t, deletes_asked(&ts), 5)

	// The correct mail verifies the account; the code is case-insensitive.
	mail_in(
		&ts,
		6,
		"carol@example.com",
		fmt.tprintf("Re: %s", strings.to_lower(acc.verify_code, context.temp_allocator)),
	)
	verify_sync(s)
	testing.expect_value(t, deletes_asked(&ts), 1)
	testing.expect(t, .Unverified not_in acc.flags)
	testing.expect_value(t, acc.verify_code, "")
	testing.expect(t, u.key in s.conns && u.key not_in s.waiting)
	events := ts_events(t, &ts, u)
	_, synced := has_event(events, .Sync_End)
	testing.expect(t, synced)
	self, told = has_event(events, .Self)
	_, _, flags, _ = proto.decode_self(self.body)
	testing.expect(t, told && .Unverified not_in flags)
	status, _ = ts_ask(t, &ts, u, .Conv_Browse)
	testing.expect_value(t, status, proto.Status.Ok)

	// A new address has to be verified again, but the account isn't deleted
	// if it isn't. The owner never has to verify.
	eb: [1 + proto.MAX_EMAIL_SIZE]u8
	status, _ = ts_ask(t, &ts, u, .Email_Set, proto.encode_email_set(eb[:], "carol@example.net"))
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect(t, .Unverified in acc.flags)
	testing.expect_value(t, acc.verify_expires, 0)
	testing.expect(t, u.key in s.waiting && u.key not_in s.conns)
	status, _ = ts_ask(t, &ts, u, .Email_Set, proto.encode_email_set(eb[:], ""))
	testing.expect_value(t, status, proto.Status.Invalid) // this server requires an address

	ts_account(t, &ts, "boss", "boss's password", {.Owner})
	boss := ts_connect(&ts)
	ts_login(t, &ts, boss, "boss", "boss's password")
	status, _ = ts_ask(t, &ts, boss, .Email_Set, proto.encode_email_set(eb[:], "boss@example.org"))
	testing.expect_value(t, status, proto.Status.Ok)
	testing.expect(t, .Unverified not_in boss.account.flags)

	// A registration that wasn't verified in time is deleted (expiry is
	// checked periodically).
	status, _ = ts_ask(
		t,
		&ts,
		ts_connect(&ts),
		.Register,
		proto.encode_register(
			buf[:],
			{username = "dave", password = "dave's password", email = "dave@example.com"},
		),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	dave := account_find(&s.accounts, "dave")
	dave.verify_expires = unix_ms() - 1
	s.verify.last_expiry = {}
	verify_sync(s)
	testing.expect(t, .Deleted in dave.flags)
	testing.expect(t, .Deleted not_in acc.flags) // kept, since she only changed her address
	testing.expect(t, account_find(&s.accounts, "dave") == nil)

	// Without check_auth_results, a mail without Authentication-Results
	// verifies the account, but the From address and the code still have to
	// be right.
	s.email.config.check_auth_results = false
	status, _ = ts_ask(
		t,
		&ts,
		ts_connect(&ts),
		.Register,
		proto.encode_register(
			buf[:],
			{username = "erin", password = "erin's password", email = "erin@example.com"},
		),
	)
	testing.expect_value(t, status, proto.Status.Ok)
	erin := account_find(&s.accounts, "erin")
	mail_in(&ts, 8, "erin@example.com", "no code", auth = "")
	verify_sync(s)
	testing.expect(t, .Unverified in erin.flags)
	mail_in(&ts, 9, "erin@example.com", erin.verify_code, auth = "")
	verify_sync(s)
	testing.expect(t, .Unverified not_in erin.flags)
	testing.expect_value(t, deletes_asked(&ts), 2)

	// Without verify_email, incoming mail is left alone.
	s.registration.verify_email = false
	mail_in(&ts, 7, "carol@example.net", "anything")
	verify_sync(s)
	testing.expect_value(t, deletes_asked(&ts), 0)
}
