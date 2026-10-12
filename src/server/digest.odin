package server

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

import "common:proto"
import "sqlite"

/*
Mailing accounts what they missed (proto.SETTING_EMAIL_DIGEST), as the
account's own setting asks:

  - Mentions: the unread messages that mention it, and its unread
    direct messages, which are as good as mentions, in every
    conversation that may tell it anything (not None);
  - Missed: those, and every other unread message in the
    conversations, channels and DMs, that tell it of every message
    (Notify_Level.All): what would have been put on its desktop, had
    it been there.

A mail lists them as direct messages, mentions, and the rest of what
came in channels, each message once.

It takes the server's email with SMTP (email.odin), and an account with
an address that isn't waiting to be verified (verify.odin). Once a
minute, every account that wants mail and has had no connection for
digest_minutes is looked at, unless no message has been posted since it
was looked at last; what it hasn't read, posted since it left and after
what it was last mailed about, goes in one mail.

After a mail, the next comes no sooner than digest_minutes later, and
tells only of what came after the newest message there was when the
last was sent (Account.digest_upto, kept in the database so a restart
doesn't send it again). Coming back and going again starts over: what
came before leaving was there to be seen.
*/

// How often accounts are looked at.
DIGEST_EVERY :: time.Minute
// The most messages each of the digest statements gives; the rest are
// only said to be there.
DIGEST_MOST :: 20
// The most of a message's text a mail quotes, in bytes.
DIGEST_QUOTE_MOST :: 200

Digest_State :: struct {
	last_check: time.Tick,
}

// digest_on is whether this server mails anyone what they missed.
digest_on :: proc(s: ^Server) -> bool {
	return s.email.enabled && s.email.config.smtp != ""
}

// digest_wait is digest_minutes, in milliseconds.
@(private = "file")
digest_wait :: proc(s: ^Server) -> i64 {
	minutes := s.email.config.digest_minutes
	if minutes <= 0 {
		minutes = DEFAULT_DIGEST_MINUTES
	}
	return i64(minutes) * 60 * 1000
}

// digest_sync mails whoever is due a digest. Called every turn of the
// loop; looks once a minute.
digest_sync :: proc(s: ^Server) {
	if !digest_on(s) ||
	   s.digest.last_check != {} && time.tick_since(s.digest.last_check) < DIGEST_EVERY {
		return
	}
	s.digest.last_check = time.tick_now()
	digests_send(s, unix_ms())
}

// digests_send mails every account that's due one at `now`.
digests_send :: proc(s: ^Server, now: i64) {
	newest := proto.Msg_Id(0)
	for _, acc in s.accounts.by_id {
		if !digest_due(s, acc, now) {
			continue
		}
		if newest == 0 {
			newest = msg_newest(s)
		}
		if acc.digest_checked >= newest {
			continue // nothing new since it was looked at
		}
		digest_account(s, acc, newest, now)
	}
}

// digest_due is whether an account may be mailed now, if anything is
// waiting for it.
@(private = "file")
digest_due :: proc(s: ^Server, acc: ^Account, now: i64) -> bool {
	wait := digest_wait(s)
	return(
		acc.digest != .None &&
		acc.email != "" &&
		acc.flags & {.Unverified, .Deleted, .Bot} == {} &&
		len(acc.conns) == 0 &&
		acc.last_seen != 0 &&
		now - acc.last_seen >= wait &&
		(acc.digest_sent == 0 || now - acc.digest_sent >= wait) \
	)
}

// msg_newest is the newest message there is, 0 for none.
@(private = "file")
msg_newest :: proc(s: ^Server) -> proto.Msg_Id {
	q := db_stmt(&s.db, .Msg_Newest)
	row, _ := db_step(&s.db, q)
	id := proto.Msg_Id(db_col_int(q, 0)) if row else 0
	sqlite.reset(q)
	return id
}

// Which part of a digest a message goes in.
Digest_Kind :: enum u8 {
	Direct, // a direct message
	Mention, // a message in a channel that mentions the account
	Channel, // anything else in a channel
}

// Digest_Item is a message a digest tells of.
Digest_Item :: struct {
	id:     proto.Msg_Id,
	conv:   proto.Conv_Id,
	sender: proto.Account_Id,
	time:   i64,
	text:   string, // in the temp allocator
	files:  bool,
	kind:   Digest_Kind,
}

/*
digest_account mails `acc` what it missed, if there's anything; `newest`
is the newest message there is. What it found is its `digest_checked`
from here on, whether there was anything or not.
*/
@(private = "file")
digest_account :: proc(s: ^Server, acc: ^Account, newest: proto.Msg_Id, now: i64) {
	items := make([dynamic]Digest_Item, context.temp_allocator)
	more: [Digest_Kind]bool
	if acc.digest == .Missed {
		digest_query(s, .Digest_Unread, acc, .Channel, &items, &more)
	}
	digest_query(s, .Digest_DMs, acc, .Direct, &items, &more)
	digest_query(s, .Digest_Mentions, acc, .Mention, &items, &more)
	if len(items) == 0 {
		acc.digest_checked = newest
		return
	}
	slice.sort_by(items[:], proc(a, b: Digest_Item) -> bool {return a.id < b.id})
	subject, body := digest_compose(s, acc, items[:], more)
	if !email_send(&s.email, acc.email, subject, body) {
		return // tried again next time
	}
	q := db_stmt(&s.db, .Account_Set_Digest)
	db_bind_int(q, 1, i64(acc.id))
	db_bind_int(q, 2, i64(newest))
	_ = db_run(&s.db, q)
	acc.digest_upto = newest
	acc.digest_checked = newest
	acc.digest_sent = now
}

/*
digest_query adds to `items` what one of the digest statements finds for
`acc`, at most DIGEST_MOST of it, as `kind` - but what's in a DM is
always Direct - and notes in `more` whether there was more. A message
already there stays once, in the part that comes first.
*/
@(private = "file")
digest_query :: proc(
	s: ^Server,
	stmt: Stmt,
	acc: ^Account,
	kind: Digest_Kind,
	items: ^[dynamic]Digest_Item,
	more: ^[Digest_Kind]bool,
) {
	q := db_stmt(&s.db, stmt)
	db_bind_int(q, 1, i64(acc.id))
	db_bind_int(q, 2, i64(acc.digest_upto))
	db_bind_int(q, 3, acc.last_seen)
	db_bind_int(q, 4, DIGEST_MOST + 1)
	found := 0
	rows: for {
		row, ok := db_step(&s.db, q)
		if !ok || !row {
			break
		}
		item := Digest_Item {
			id     = proto.Msg_Id(db_col_int(q, 0)),
			conv   = proto.Conv_Id(db_col_int(q, 1)),
			sender = proto.Account_Id(db_col_int(q, 2)),
			time   = db_col_int(q, 3),
			files  = .Has_Attachments in transmute(proto.Msg_Flags)u8(db_col_int(q, 5)),
			kind   = kind,
		}
		if conv := s.convs.by_id[item.conv] or_else nil; conv != nil && conv.kind == .DM {
			item.kind = .Direct
		}
		if found == DIGEST_MOST {
			more[item.kind] = true
			break
		}
		found += 1
		for &have in items {
			if have.id == item.id {
				have.kind = min(have.kind, item.kind)
				continue rows
			}
		}
		item.text = db_col_text(q, 4)
		append(items, item)
	}
	sqlite.reset(q)
}

/*
digest_compose writes a digest's subject and plain text body, in the
temp allocator. `more` says which parts have more than they list.
*/
digest_compose :: proc(
	s: ^Server,
	acc: ^Account,
	items: []Digest_Item,
	more: [Digest_Kind]bool,
) -> (
	subject, body: string,
) {
	server := s.name if s.name != "" else "yap"
	@(static, rodata)
	names := [Digest_Kind][2]string {
		.Direct  = {"direct message", "direct messages"},
		.Mention = {"mention", "mentions"},
		.Channel = {"channel message", "channel messages"},
	}
	counts: [Digest_Kind]int
	for item in items {
		counts[item.kind] += 1
	}
	parts := make([dynamic]string, context.temp_allocator)
	for n, kind in counts {
		if n > 0 {
			many := n > 1 || more[kind]
			append(
				&parts,
				fmt.tprintf(
					"%d%s %s",
					n,
					"+" if more[kind] else "",
					names[kind][1 if many else 0],
				),
			)
		}
	}

	tagline := ""
	switch len(parts) {
	case 1:
		tagline = fmt.tprintf("%s on %s", parts[0], server)
	case 2:
		tagline = fmt.tprintf("%s and %s on %s", parts[0], parts[1], server)
	case:
		tagline = fmt.tprintf("%s, %s and %s on %s", parts[0], parts[1], parts[2], server)
	}
	subject = fmt.tprintf("Missed messages on %s", server)
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "Hi %s,\n\nyou've missed %s:\n", acc.display, tagline)
	section :: proc(
		b: ^strings.Builder,
		s: ^Server,
		title: string,
		items: []Digest_Item,
		kind: Digest_Kind,
		more: bool,
	) {
		first := true
		for item in items {
			if item.kind != kind {
				continue
			}
			if first {
				fmt.sbprintf(b, "\n%s\n\n", title)
				first = false
			}
			from := DELETED_NAME_FALLBACK
			if sender := account_by_id(&s.accounts, item.sender); sender != nil {
				from = sender.display
			}
			place := ""
			if conv := s.convs.by_id[item.conv] or_else nil; conv != nil && kind != .Direct {
				place = fmt.tprintf(" in #%s", conv.name)
			}
			fmt.sbprintf(
				b,
				"  %s%s, %s:\n    %s\n",
				from,
				place,
				digest_time(item.time),
				digest_quote(s, item),
			)
		}
		if more && !first {
			strings.write_string(b, "  ... and more.\n")
		}
	}
	section(&b, s, "Direct messages", items, .Direct, more[.Direct])
	section(&b, s, "Mentions", items, .Mention, more[.Mention])
	section(&b, s, "In your channels", items, .Channel, more[.Channel])
	strings.write_string(&b, "\nOpen yap to read and answer them.\n\n-- \n")
	fmt.sbprintf(
		&b,
		"You get this mail because you asked %s for it. To stop it, set\nEmail digests to \"No emails\" in your account settings there.\n",
		server,
	)
	return subject, strings.to_string(b)
}

// Who wrote a message whose account is gone from memory, which shouldn't
// happen: accounts are kept, deleted ones as tombstones.
@(private = "file")
DELETED_NAME_FALLBACK :: "Somebody"

/*
digest_quote is a message's text as a digest quotes it, in the temp
allocator: mentions as names, on one line, cut at DIGEST_QUOTE_MOST.
*/
digest_quote :: proc(s: ^Server, item: Digest_Item) -> string {
	if item.text == "" {
		return "(sent a file)" if item.files else "(no text)"
	}
	b := strings.builder_make(context.temp_allocator)
	at := 0
	for {
		m, ok := proto.next_mention(item.text, at)
		if !ok {
			break
		}
		strings.write_string(&b, item.text[at:m.start])
		switch {
		case m.everyone:
			strings.write_string(&b, "@" + proto.MENTION_EVERYONE)
		case m.role != 0:
			r := s.accounts.roles[m.role] or_else nil
			fmt.sbprintf(&b, "@%s", r.name if r != nil else "role")
		case:
			a := account_by_id(&s.accounts, m.account)
			fmt.sbprintf(&b, "@%s", a.display if a != nil else "somebody")
		}
		at = m.end
	}
	strings.write_string(&b, item.text[at:])
	text := strings.join(
		strings.fields(strings.to_string(b), context.temp_allocator),
		" ",
		context.temp_allocator,
	)
	if len(text) > DIGEST_QUOTE_MOST {
		n := DIGEST_QUOTE_MOST
		for n > 0 && !utf8.rune_start(text[n]) {
			n -= 1
		}
		text = fmt.tprintf("%s...", text[:n])
	}
	return text
}

// digest_time is when a message was posted, as a digest says it: the
// server doesn't know the reader's time zone, so in UTC.
digest_time :: proc(ms: i64) -> string {
	t := time.unix(ms / 1000, 0)
	year, month, day := time.date(t)
	hour, minute, _ := time.clock_from_time(t)
	return fmt.tprintf("%d-%02d-%02d %02d:%02d UTC", year, int(month), day, hour, minute)
}
