package server

import "core:strings"
import "core:testing"
import "core:time"

import "common:proto"

// Tests of reading and writing mail (email.odin), without a mail server.

@(test)
test_mail_parse :: proc(t: ^testing.T) {
	header :=
		"Return-Path: <alice@example.com>\r\n" +
		"Authentication-Results: mx.example.org;\r\n" +
		"\tdkim=pass header.d=example.com;\r\n" +
		"\tspf=pass smtp.mailfrom=alice@example.com\r\n" +
		"Authentication-Results: elsewhere.example; spf=fail\r\n" +
		"From: Alice Example <Alice@Example.COM>\r\n" +
		"Subject: =?UTF-8?B?VmVyaWZ5?= =?UTF-8?Q?_ABC123_=C3=A4?=\r\n" +
		"Date: Tue, 06 Oct 2026 08:00:00 +0000\r\n" +
		"\r\n" +
		"Subject: not a header, the body\r\n"
	m := mail_parse(5, header)
	defer mail_destroy(&m)
	testing.expect_value(t, m.uid, 5)
	testing.expect_value(t, m.from, "alice@example.com")
	testing.expect_value(t, m.subject, "Verify ABC123 ä")
	testing.expect_value(t, m.date, "Tue, 06 Oct 2026 08:00:00 +0000")
	testing.expect_value(t, len(m.auth_results), 2)
	if len(m.auth_results) == 2 {
		testing.expect_value(
			t,
			m.auth_results[0],
			"mx.example.org; dkim=pass header.d=example.com; spf=pass smtp.mailfrom=alice@example.com",
		)
	}

	// Bare LF line ends, a bare address, nothing else.
	n := mail_parse(7, "From: bob@example.net\nSubject: plain\n")
	defer mail_destroy(&n)
	testing.expect_value(t, n.from, "bob@example.net")
	testing.expect_value(t, n.subject, "plain")
	testing.expect_value(t, n.date, "")
	testing.expect_value(t, len(n.auth_results), 0)

	// No address to be had.
	o := mail_parse(8, "From: Mailer Daemon\r\n\r\n")
	defer mail_destroy(&o)
	testing.expect_value(t, o.from, "")
}

@(test)
test_decode_words :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, value, want: string, loc := #caller_location) {
		got := decode_words(value)
		defer delete(got)
		testing.expect_value(t, got, want, loc)
	}
	check(t, "plain text", "plain text")
	check(t, "=?utf-8?q?caf=C3=A9_au_lait?=", "café au lait")
	check(t, "=?UTF-8?B?w6Q=?= =?UTF-8?B?w7Y=?=", "äö") // the space between goes
	check(t, "Re: =?UTF-8?B?w6Q=?= and more", "Re: ä and more")
	check(t, "=?UTF-8?X?abc?= stays", "=?UTF-8?X?abc?= stays")
	check(t, "=?broken", "=?broken")
	check(t, "=?UTF-8?Q?bad=Z?=", "=?UTF-8?Q?bad=Z?=")
}

@(test)
test_imap_search_uids :: proc(t: ^testing.T) {
	uids := imap_search_uids("* SEARCH 4 7 19\r\n")
	testing.expect_value(t, len(uids), 3)
	if len(uids) == 3 {
		testing.expect_value(t, uids[2], 19)
	}
	testing.expect_value(t, len(imap_search_uids("* SEARCH\r\n")), 0)
	testing.expect_value(t, len(imap_search_uids("* OK nothing\r\n* search 3 x 0\r\n")), 1)
}

@(test)
test_email_clean :: proc(t: ^testing.T) {
	buf: [proto.MAX_EMAIL_SIZE]u8
	address, ok := proto.email_clean("  Alice@Example.COM ", &buf)
	testing.expect(t, ok)
	testing.expect_value(t, address, "alice@example.com")
	for bad in ([]string{"", "alice", "alice@", "@example.com", "a@b@example.com", "alice@example", "alice@.com", "alice@example.", "al ice@example.com", "<alice@example.com>", "alice@example.com\r\nBcc: x@y.z"}) {
		_, bad_ok := proto.email_clean(bad, &buf)
		testing.expectf(t, !bad_ok, "%q taken for an address", bad)
	}
}

@(test)
test_mail_compose :: proc(t: ^testing.T) {
	when_ := time.unix(1791273600, 0) // Tue, 06 Oct 2026 08:00:00 UTC
	testing.expect_value(t, rfc5322_date(when_), "Tue, 06 Oct 2026 08:00:00 +0000")

	mail := mail_compose("yap@example.org", "bob@example.net", "Hi", "one\ntwo\r\n", when_)
	testing.expect(t, strings.contains(mail, "Date: Tue, 06 Oct 2026 08:00:00 +0000\r\n"))
	testing.expect(t, strings.contains(mail, "From: <yap@example.org>\r\n"))
	testing.expect(t, strings.contains(mail, "To: <bob@example.net>\r\n"))
	testing.expect(t, strings.contains(mail, "Subject: Hi\r\n"))
	testing.expect(t, strings.contains(mail, "@example.org>\r\n"))
	testing.expect(t, strings.has_suffix(mail, "\r\n\r\none\r\ntwo\r\n"))

	// Not ASCII: encoded, and read back the same.
	subject := "Grüße aus der Ferne, mit einer Betreffzeile, die lang genug ist"
	mail = mail_compose("yap@example.org", "bob@example.net", subject, "", when_)
	start := strings.index(mail, "Subject: ") + len("Subject: ")
	end := strings.index(mail, "\r\nMessage-ID")
	encoded := mail[start:end]
	testing.expect(t, strings.has_prefix(encoded, "=?UTF-8?B?"))
	testing.expect(t, strings.contains(encoded, "\r\n ")) // more than one word
	unfolded, _ := strings.replace_all(encoded, "\r\n ", " ", context.temp_allocator)
	decoded := decode_words(unfolded)
	defer delete(decoded)
	testing.expect_value(t, decoded, subject)
}
