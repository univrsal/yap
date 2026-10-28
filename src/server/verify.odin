package server

import "core:fmt"
import "core:log"
import "core:strings"
import "core:time"

import "common:proto"
import "mail"

// Verification of the email addresses of accounts (see proto/verify.odin).
// It uses the server's mailbox (see mail/mail.odin) and is active when the
// registration config has verify_email set.
//
// An account is Unverified from the moment it registers until an email
// arrives that proves the address belongs to the account's owner. Changing
// the address (Email_Set) makes the account Unverified again, except for the
// owner's account, which is never locked out of the server. An Unverified
// account can log in like any other, but it is hidden from everyone else
// (conn_login keeps its connections in Server.waiting) and may only send
// Email_Set, Auth_Logout and Account_Delete requests (see rpc.odin).
//
// An email verifies an account if all of the following are true:
//   - Its From address is the account's address.
//   - Its subject contains the account's code. Otherwise somebody could
//     claim another person's address by registering with it and then
//     waiting for the owner to email the server for some other reason.
//   - The topmost Authentication-Results header, which is added by the
//     receiving mail server, comes from trusted_auth_host and says that
//     DMARC, DKIM or SPF passed for the domain of the From address.
//     Anybody can write any From address, so this header is what proves that
//     the email really came from that domain. Lower headers, and headers
//     from other hosts, could have been written by the sender. If the
//     config's check_auth_results is false, this check is skipped for mail
//     servers that don't add such a header, and the From address is trusted.
//
// Every email the server reads is deleted after it was looked at, whether or
// not it verified anything (D8). Registrations that aren't verified within
// unverified_hours are deleted (account_erase), a few each minute.

// How often unverified registrations are checked for ones that are too old,
// and how many are deleted at once.
VERIFY_EXPIRE_EVERY :: time.Minute
VERIFY_EXPIRE_MOST :: 10

Verify_State :: struct {
	last_expiry: time.Tick,
}

// verify_on returns whether this server verifies email addresses at all.
verify_on :: proc(s: ^Server) -> bool {
	return s.registration.verify_email && s.email.enabled
}

// verify_code_new generates a new random verification code.
@(private = "file")
verify_code_new :: proc(out: ^[proto.VERIFY_CODE_SIZE]u8) -> string {
	alphabet := proto.INVITE_ALPHABET
	for &ch in out {
		ch = alphabet[random_below(len(alphabet))]
	}
	return string(out[:])
}

// account_unverify makes an account Unverified and gives it a new code. The
// account is deleted if it isn't verified by the time `by` (0 means that
// the account is never deleted for lack of a verification email). Its
// connections are hidden from everyone else and are told what to do.
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

// account_verified marks an account as verified after its address has been
// shown to be its own. The account is let in and becomes visible to everyone.
account_verified :: proc(s: ^Server, acc: ^Account) -> bool {
	// Only a registration has a deadline to be verified by; an account that
	// changed its address was there already.
	registered := acc.verify_expires != 0
	account_set_verify(&s.accounts, acc, acc.flags - {.Unverified}, "", 0) or_return
	log.infof("%s's email address %s is verified", acc.username, acc.email)
	account_changed(s, acc)
	if registered {
		account_joined(s, acc)
	}
	for u in acc.conns {
		conn_seen(s, u)
	}
	return true
}

// verify_sync checks the emails that have arrived and verifies the
// addresses they prove, then deletes them. Without verify_email the emails
// are only logged and are left in the mailbox.
verify_sync :: proc(s: ^Server) {
	for {
		m := mail.poll(&s.email) or_break
		defer mail.message_destroy(&m)
		if !s.registration.verify_email {
			log.debugf("mail %d from %q: %q", m.uid, m.from, m.subject)
			continue
		}
		acc := account_by_email(&s.accounts, m.from)
		switch {
		case acc == nil || .Unverified not_in acc.flags:
			log.debugf("mail from %q doesn't match any unverified account: %q", m.from, m.subject)
		case !subject_has_code(m.subject, acc.verify_code):
			log.debugf("mail from %q doesn't have %s's code: %q", m.from, acc.username, m.subject)
		case s.email.config.check_auth_results &&
		     !auth_passed(m.auth_results, s.email.config.trusted_auth_host, m.from):
			// The log message includes what was found in the email because
			// that is what an admin needs to set trusted_auth_host correctly,
			// and the email is deleted after this.
			found := "it has no Authentication-Results header"
			if len(m.auth_results) > 0 {
				found = fmt.tprintf(
					"its topmost Authentication-Results, of %d, is %q",
					len(m.auth_results),
					m.auth_results[0],
				)
			}
			log.infof(
				"mail from %q for %s was not shown to come from that domain by %s: %s",
				m.from,
				acc.username,
				s.email.config.trusted_auth_host,
				found,
			)
		case:
			account_verified(s, acc)
		}
		mail.delete_mail(&s.email, m.uid)
	}
	verify_expire(s)
}

// verify_expire deletes registrations that waited too long for their
// verification email, a few at a time.
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
		log.infof("%s never verified its email address, so the account is deleted", acc.username)
		if !account_erase(s, acc) {
			log.errorf("could not delete %s", acc.username)
		}
	}
}

// subject_has_code returns whether a subject contains the code, ignoring case.
subject_has_code :: proc(subject, code: string) -> bool {
	if code == "" {
		return false
	}
	return strings.contains(strings.to_upper(subject, context.temp_allocator), code)
}

// auth_passed returns whether the topmost Authentication-Results header
// (RFC 8601) comes from the `trusted` host and says that the mail is from
// the domain of `from`. That is the case if DMARC passed for the domain, if
// DKIM passed with a signature of the domain, or if SPF passed for an
// envelope sender in the domain. A domain also matches its subdomains
// (relaxed alignment).
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
	// The authserv-id, optionally followed by a version.
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

	// The part after the @, or the whole value if there is no @.
	domain_part :: proc(value: string) -> string {
		if at := strings.last_index_byte(value, '@'); at >= 0 {
			return value[at + 1:]
		}
		return value
	}
	// Returns whether `raw` is `domain` or a parent domain of it.
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

// strip_comments removes the (comments) from a header's value. Comments may
// be nested. Quoted text is left unchanged.
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
