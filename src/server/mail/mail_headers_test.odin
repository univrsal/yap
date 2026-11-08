package mail

import "core:encoding/base64"
import "core:strings"
import "core:testing"
import "core:time"
import "core:unicode/utf8"

import "../curl"

// More tests of the mail code (mail.odin): addresses, dates, the headers that
// are written, and when a connection must be encrypted.

@(test)
test_address_of :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, from, want: string, loc := #caller_location) {
		got := address_of(from)
		defer delete(got)
		testing.expect_value(t, got, want, loc)
	}
	check(t, "alice@example.org", "alice@example.org")
	check(t, "Alice@Example.ORG", "alice@example.org")
	check(t, "Alice <Alice@Example.org>", "alice@example.org")
	check(t, `"Smith, Alice" <alice@example.org>`, "alice@example.org")
	check(t, "<alice@example.org>", "alice@example.org")
	check(t, "  alice@example.org  ", "alice@example.org")
	// The last address in angle brackets is the one meant.
	check(t, "alice@evil.org <bob@example.org>", "bob@example.org")
	// A display name that looks like an address doesn't count either.
	check(t, `"<alice@evil.org>" <bob@example.org>`, "bob@example.org")
	// A display name can't smuggle in a different address.
	check(t, `"alice@example.org" <bob@example.org>`, "bob@example.org")

	for bad in ([]string {
			"",
			"Alice",
			"Alice <>",
			"Alice <not an address>",
			"Alice <alice@example>",
			"alice@example.org>",
			"<alice@example.org",
			"alice@example.org, bob@example.org",
			"alice@example.org\r\nBcc: bob@example.org",
		}) {
		check(t, bad, "")
	}
}

@(test)
test_url_base :: proc(t: ^testing.T) {
	testing.expect_value(t, url_base("imaps://mail.example.org"), "imaps://mail.example.org")
	testing.expect_value(t, url_base("imaps://mail.example.org/"), "imaps://mail.example.org")
	testing.expect_value(
		t,
		url_base("imaps://mail.example.org:993///"),
		"imaps://mail.example.org:993",
	)
	testing.expect_value(t, url_base(""), "")
}

@(test)
test_tls_is_required_from_remote_servers :: proc(t: ^testing.T) {
	// A server that isn't on this machine must offer TLS.
	for url in ([]string {
			"imaps://mail.example.org",
			"imap://mail.example.org",
			"smtps://smtp.example.org:465",
			"smtp://smtp.example.org:587",
			"imap://mail.example.org:143/INBOX",
			"mail.example.org",
			"imap://notlocalhost",
			"imap://localhost.example.org",
			"imap://10.0.0.5", // private is not this machine
			"imap://192.168.1.2:143",
			"imap://[::2]",
			"",
		}) {
		testing.expectf(t, tls_wanted(url) == curl.USESSL_ALL, "%q may go without TLS", url)
	}
	// One on this machine may go without.
	for url in ([]string {
			"imap://localhost",
			"imap://localhost:143",
			"smtp://localhost:25/",
			"imap://127.0.0.1",
			"imap://127.0.0.1:143",
			"smtp://127.1.2.3:25",
			"imap://[::1]",
			"imap://[::1]:143",
			"localhost",
		}) {
		testing.expectf(t, tls_wanted(url) == curl.USESSL_TRY, "%q must use TLS", url)
	}
}

@(test)
test_rfc5322_date :: proc(t: ^testing.T) {
	testing.expect_value(t, rfc5322_date(time.unix(0, 0)), "Thu, 01 Jan 1970 00:00:00 +0000")
	// Numbers are padded to two digits.
	testing.expect_value(
		t,
		rfc5322_date(time.unix(1788577445, 0)),
		"Sat, 05 Sep 2026 03:04:05 +0000",
	)
	testing.expect_value(
		t,
		rfc5322_date(time.unix(1709210096, 0)),
		"Thu, 29 Feb 2024 12:34:56 +0000",
	)
	testing.expect_value(
		t,
		rfc5322_date(time.unix(978307199, 0)),
		"Sun, 31 Dec 2000 23:59:59 +0000",
	)
	// Every weekday and month is named.
	seen_days, seen_months: map[string]bool
	defer delete(seen_days)
	defer delete(seen_months)
	for i in 0 ..< 366 {
		d := rfc5322_date(time.unix(i64(1700000000 + i * 86400), 0))
		seen_days[d[:3]] = true
		seen_months[d[8:11]] = true
	}
	testing.expect_value(t, len(seen_days), 7)
	testing.expect_value(t, len(seen_months), 12)
}

// header returns the value of a header in a composed mail.
@(private = "file")
header :: proc(mail, name: string) -> (value: string, found: bool) {
	head := mail[:strings.index(mail, "\r\n\r\n")]
	for line in strings.split_lines_iterator(&head) {
		if strings.has_prefix(line, name) && strings.has_prefix(line[len(name):], ": ") {
			return line[len(name) + 2:], true
		}
	}
	return
}

@(test)
test_compose_cannot_be_given_headers :: proc(t: ^testing.T) {
	when_ := time.unix(1791273600, 0)

	// A line break in a subject would end the header and start a new one.
	for subject in ([]string {
			"Hi\r\nBcc: evil@example.net",
			"Hi\nBcc: evil@example.net",
			"Hi\rBcc: evil@example.net",
			"Hi\x00there",
		}) {
		mail := compose("yap@example.org", "bob@example.net", subject, "body", when_)
		head := mail[:strings.index(mail, "\r\n\r\n")]
		testing.expectf(t, !strings.contains(head, "Bcc"), "%q added a header", subject)
		subject_line, found := header(mail, "Subject")
		testing.expect(t, found)
		testing.expect(t, !strings.contains_any(subject_line, "\r\n\x00"))
		// Every line of the header is a header or a fold of one.
		lines := strings.split(head, "\r\n", context.temp_allocator)
		for line in lines {
			ok := line[0] == ' ' || strings.contains(line, ": ")
			testing.expectf(t, ok, "%q is not a header", line)
		}
	}

	// The body can't end the message early either: every line ends in CRLF.
	mail := compose("yap@example.org", "bob@example.net", "Hi", "a\n.\nb\r\nc", when_)
	body := mail[strings.index(mail, "\r\n\r\n") + 4:]
	testing.expect_value(t, body, "a\r\n.\r\nb\r\nc\r\n")
	testing.expect(t, !strings.contains(strings.trim_suffix(body, "\r\n"), "\n\n"))
}

@(test)
test_compose_headers :: proc(t: ^testing.T) {
	mail := compose("yap@example.org", "bob@example.net", "", "", time.unix(1791273600, 0))
	subject, found := header(mail, "Subject")
	testing.expect(t, found)
	testing.expect_value(t, subject, "")
	id, id_found := header(mail, "Message-ID")
	testing.expect(t, id_found)
	testing.expect(t, strings.has_prefix(id, "<") && strings.has_suffix(id, "@example.org>"))
	ctype, _ := header(mail, "Content-Type")
	testing.expect_value(t, ctype, "text/plain; charset=utf-8")
	version, _ := header(mail, "MIME-Version")
	testing.expect_value(t, version, "1.0")

	// Two mails get different ids.
	other := compose("yap@example.org", "bob@example.net", "", "", time.unix(1791273600, 0))
	other_id, _ := header(other, "Message-ID")
	testing.expect(t, id != other_id)
}

@(test)
test_compose_encodes_subjects_in_whole_characters :: proc(t: ^testing.T) {
	when_ := time.unix(1791273600, 0)
	// Characters of two, three and four bytes, so that a split every 45 bytes
	// lands in the middle of one for some of the lengths.
	for unit in ([]string{"é", "€", "😀", "aé€😀"}) {
		for count in 1 ..= 40 {
			subject := strings.repeat(unit, count, context.temp_allocator)
			mail := compose("yap@example.org", "bob@example.net", subject, "", when_)
			encoded, _ := header(mail, "Subject")
			// The folded lines are in the temp allocator. Join them back.
			head := mail[:strings.index(mail, "\r\n\r\n")]
			start := strings.index(head, "Subject: ") + len("Subject: ")
			end := strings.index(head[start:], "\r\nMessage-ID") + start
			folded := head[start:end]
			_ = encoded

			whole := strings.builder_make(context.temp_allocator)
			for word in strings.split(folded, "\r\n ", context.temp_allocator) {
				testing.expectf(
					t,
					strings.has_prefix(word, "=?UTF-8?B?") && strings.has_suffix(word, "?="),
					"%q",
					word,
				)
				testing.expect(t, len(word) <= 75, "an encoded word is longer than 75 characters")
				b64 := word[len("=?UTF-8?B?"):len(word) - 2]
				raw, err := base64.decode(b64, allocator = context.temp_allocator)
				testing.expect(t, err == nil)
				// Each word is valid on its own, so a reader can decode them one by one.
				testing.expectf(
					t,
					utf8.valid_string(string(raw)),
					"a word of %q splits a character",
					unit,
				)
				strings.write_bytes(&whole, raw)
			}
			testing.expect_value(t, strings.to_string(whole), subject)
		}
	}
}

@(test)
test_config_copy :: proc(t: ^testing.T) {
	original := Config {
		address            = strings.clone("yap@example.org"),
		imap               = strings.clone("imaps://mail.example.org"),
		smtp               = strings.clone("smtps://mail.example.org"),
		username           = strings.clone("yap"),
		password           = strings.clone("secret"),
		poll_seconds       = 30,
		check_auth_results = true,
		trusted_auth_host  = strings.clone("mx.example.org"),
		digest_minutes     = 15,
	}
	copied := config_clone(original)
	// The copy has strings of its own, which survive the original's.
	testing.expect(t, raw_data(copied.password) != raw_data(original.password))
	config_destroy(&original)
	testing.expect_value(t, copied.address, "yap@example.org")
	testing.expect_value(t, copied.imap, "imaps://mail.example.org")
	testing.expect_value(t, copied.smtp, "smtps://mail.example.org")
	testing.expect_value(t, copied.username, "yap")
	testing.expect_value(t, copied.password, "secret")
	testing.expect_value(t, copied.trusted_auth_host, "mx.example.org")
	testing.expect_value(t, copied.poll_seconds, 30)
	testing.expect_value(t, copied.digest_minutes, 15)
	testing.expect(t, copied.check_auth_results)
	config_destroy(&copied)
}
