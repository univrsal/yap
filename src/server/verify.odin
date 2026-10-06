package server

import "core:fmt"
import "core:log"
import "core:strings"
import "core:time"

import "common:proto"

/*
Verifying accounts' email addresses (proto/verify.odin), with the
server's mail (email.odin), when the config's registration has
verify_email.

An account is Unverified from when it registers until a mail comes that
shows the address is its owner's. Changing the address (Email_Set) makes
it Unverified again, but for the owner's, who is never locked out of
the server. An Unverified account logs in like any other, but stays out
of everyone's sight (conn_login keeps its connections in Server.waiting)
and may ask nothing but Email_Set, Auth_Logout and Account_Delete (rpc.odin).

A mail verifies an account when
  - its From is the account's address,
  - its subject has the account's code in it, so that nobody can claim
    somebody else's address by registering with it and waiting for its
    owner to mail the server for some other reason, and
  - the topmost Authentication-Results header, which the receiving mail
    server adds, is from trusted_auth_host and says DMARC, DKIM or SPF
    passed for the From's domain. Anybody can write any From; this is
    what says the mail really came from that domain. Lower headers, and
    any of other hosts', could have been written by the sender. With
    the config's check_auth_results false this isn't asked, for mail
    servers that add no such header; then the From is taken at its
    word.

Every mail the server reads is deleted once looked at, whether it
verified anything or not (D8). Registrations that aren't verified in
unverified_hours are deleted (account_erase), a few each minute.
*/

// How often unverified registrations are looked at for ones too old,
// and how many go at once.
VERIFY_EXPIRE_EVERY :: time.Minute
VERIFY_EXPIRE_MOST :: 10

Verify_State :: struct {
	last_expiry: time.Tick,
}

// verify_on is whether this server verifies addresses at all.
verify_on :: proc(s: ^Server) -> bool {
	return s.registration.verify_email && s.email.enabled
}

// verify_code_new is a new random code.
@(private = "file")
verify_code_new :: proc(out: ^[proto.VERIFY_CODE_SIZE]u8) -> string {
	alphabet := proto.INVITE_ALPHABET
	for &ch in out {
		ch = alphabet[random_below(len(alphabet))]
	}
	return string(out[:])
}

/*
account_unverify makes an account Unverified, with a new code, until
`by` (0: it isn't deleted for want of a mail); its connections go out of
everyone's sight, and are told what to do.
*/
account_unverify :: proc(s: ^Server, acc: ^Account, by: i64) -> bool {
	buf: [proto.VERIFY_CODE_SIZE]u8
	code := verify_code_new(&buf)
	account_set_verify(&s.accounts, acc, acc.flags + {.Unverified}, code, by) or_return
	moved := false
	for u in acc.conns {
		if u.key in s.conns {
			conn_unseen(s, u)
			moved = true
		}
		send_self(u)
	}
	if moved {
		bump_version(s)
		activity_check(s, acc)
	}
	return true
}

// account_verified is an account's address shown to be its own: it's
// let in, and everyone sees it.
account_verified :: proc(s: ^Server, acc: ^Account) -> bool {
	account_set_verify(&s.accounts, acc, acc.flags - {.Unverified}, "", 0) or_return
	log.infof("%s's email address %s is verified", acc.username, acc.email)
	account_changed(s, acc)
	for u in acc.conns {
		conn_seen(s, u)
	}
	return true
}

/*
verify_sync looks at the mail that has come in for addresses it
verifies, and deletes it. Without verify_email the mail is only logged,
and left where it is.
*/
verify_sync :: proc(s: ^Server) {
	for {
		m := email_poll(&s.email) or_break
		defer mail_destroy(&m)
		if !s.registration.verify_email {
			log.debugf("mail %d from %q: %q", m.uid, m.from, m.subject)
			continue
		}
		acc := account_by_email(&s.accounts, m.from)
		switch {
		case acc == nil || .Unverified not_in acc.flags:
			log.debugf("mail from %q verifies nobody: %q", m.from, m.subject)
		case !subject_has_code(m.subject, acc.verify_code):
			log.debugf("mail from %q doesn't have %s's code: %q", m.from, acc.username, m.subject)
		case s.email.config.check_auth_results &&
		     !auth_passed(m.auth_results, s.email.config.trusted_auth_host, m.from):
			// What it says is what's needed to set trusted_auth_host right,
			// and the mail is gone after this.
			found := "it has no Authentication-Results header"
			if len(m.auth_results) > 0 {
				found = fmt.tprintf(
					"its topmost Authentication-Results, of %d, is %q",
					len(m.auth_results),
					m.auth_results[0],
				)
			}
			log.infof(
				"mail from %q for %s isn't shown to be from there by %s: %s",
				m.from,
				acc.username,
				s.email.config.trusted_auth_host,
				found,
			)
		case:
			account_verified(s, acc)
		}
		email_delete(&s.email, m.uid)
	}
	verify_expire(s)
}

// verify_expire deletes registrations that waited too long for their
// mail, a few at a time.
@(private = "file")
verify_expire :: proc(s: ^Server) {
	v := &s.verify
	if v.last_expiry != {} && time.tick_since(v.last_expiry) < VERIFY_EXPIRE_EVERY {
		return
	}
	v.last_expiry = time.tick_now()
	now := unix_ms()
	expired := make([dynamic]^Account, context.temp_allocator)
	for _, acc in s.accounts.by_id {
		if .Unverified in acc.flags && acc.verify_expires != 0 && acc.verify_expires <= now {
			append(&expired, acc)
			if len(expired) == VERIFY_EXPIRE_MOST {
				break
			}
		}
	}
	for acc in expired {
		log.infof("%s never verified its email address, so it's deleted", acc.username)
		if !account_erase(s, acc) {
			log.errorf("could not delete %s", acc.username)
		}
	}
}

// subject_has_code says whether a subject has a code in it, in any case.
subject_has_code :: proc(subject, code: string) -> bool {
	if code == "" {
		return false
	}
	return strings.contains(strings.to_upper(subject, context.temp_allocator), code)
}

/*
auth_passed says whether the topmost Authentication-Results header
(RFC 8601) is `trusted`'s and says the mail is from the domain of
`from`: DMARC passed for it, or DKIM passed with a signature of it, or
SPF passed for an envelope sender of it. A domain counts as its own and
its subdomains' (relaxed alignment).
*/
auth_passed :: proc(results: []string, trusted, from: string) -> bool {
	if len(results) == 0 || trusted == "" {
		return false
	}
	at := strings.last_index_byte(from, '@')
	if at < 0 {
		return false
	}
	domain := from[at + 1:]
	text := strip_comments(results[0])
	parts := strings.split(text, ";", context.temp_allocator)
	// authserv-id, maybe followed by a version.
	id_fields := strings.fields(parts[0], context.temp_allocator)
	if len(id_fields) == 0 || !strings.equal_fold(id_fields[0], trusted) {
		return false
	}
	for part in parts[1:] {
		fields := strings.fields(part, context.temp_allocator)
		if len(fields) == 0 {
			continue
		}
		method, _, result := strings.partition(fields[0], "=")
		if !strings.equal_fold(result, "pass") {
			continue
		}
		for prop in fields[1:] {
			name, _, value := strings.partition(prop, "=")
			value = strings.trim(value, "\"")
			ok := false
			switch {
			case strings.equal_fold(method, "dmarc") && strings.equal_fold(name, "header.from"):
				ok = aligned(value, domain)
			case strings.equal_fold(method, "dkim") && strings.equal_fold(name, "header.d"):
				ok = aligned(value, domain)
			case strings.equal_fold(method, "dkim") && strings.equal_fold(name, "header.i"):
				ok = aligned(domain_part(value), domain)
			case strings.equal_fold(method, "spf") && strings.equal_fold(name, "smtp.mailfrom"):
				ok = aligned(domain_part(value), domain)
			}
			if ok {
				return true
			}
		}
	}
	return false

	// What comes after the @, or all of it.
	domain_part :: proc(value: string) -> string {
		if at := strings.last_index_byte(value, '@'); at >= 0 {
			return value[at + 1:]
		}
		return value
	}
	// Whether `d` is `domain` or a parent of it.
	aligned :: proc(raw, domain: string) -> bool {
		d := strings.trim_suffix(raw, ".")
		if d == "" {
			return false
		}
		if strings.equal_fold(d, domain) {
			return true
		}
		return(
			len(domain) > len(d) + 1 &&
			domain[len(domain) - len(d) - 1] == '.' &&
			strings.equal_fold(domain[len(domain) - len(d):], d) \
		)
	}
}

// strip_comments takes the (comments) out of a header's value, which may
// be nested; quoted text is left as it is.
@(private = "file")
strip_comments :: proc(value: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	depth := 0
	quoted := false
	for i in 0 ..< len(value) {
		ch := value[i]
		switch {
		case quoted:
			if ch == '"' {
				quoted = false
			}
		case ch == '"' && depth == 0:
			quoted = true
		case ch == '(':
			depth += 1
			continue
		case ch == ')' && depth > 0:
			depth -= 1
			continue
		}
		if depth == 0 {
			strings.write_byte(&b, ch)
		}
	}
	return strings.to_string(b)
}
