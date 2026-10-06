package server

import "base:runtime"
import "core:crypto"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:fmt"
import "core:log"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:unicode/utf8"

import "common:proto"

/*
The server's own email account (config.json's "email", see config.odin):
it reads what's sent to it over IMAP, and sends over SMTP, both through
libcurl (curl.odin). Nothing reads its mail yet; verifying an account's
address by mail will (docs/next, item 8), and password resets and
missed-mention mails will send it.

Mail is slow and may hang, so it's all on a thread of its own, which
the loop talks to through two queues, like the password hasher's
(hash_worker.odin):

- every poll_seconds, and whenever asked, the thread asks the INBOX for
  the mails it hasn't seen (UID SEARCH UNSEEN), fetches each one's
  header - which marks it seen - and queues it for the loop as a Mail:
  who it's from, its subject, its date and its Authentication-Results.
  The loop takes them with email_poll;
- the loop queues what it wants done: a mail to send (email_send), or a
  mail it's done with to delete (email_delete).

The loop never waits for any of it. A mail server that can't be reached
is logged when it starts failing and when it's back, and tried again at
the next poll.

The addresses in the config are URLs: imaps:// and smtps:// connect with
TLS; imap:// and smtp:// are upgraded with STARTTLS, which a server that
isn't this machine must offer - the password never goes out in the
clear - while one on this machine (localhost, 127.x) may do without.
*/

Email_Config :: struct {
	address:           string, // the server's address; empty: no email
	imap:              string, // imaps://host[:port]
	smtp:              string, // smtps://host[:port]; empty: no sending
	username:          string, // empty: the address
	password:          string,
	poll_seconds:      int,
	// The mail server whose Authentication-Results are to be believed
	// (item 8); other hosts' are anybody's say-so.
	trusted_auth_host: string,
}

DEFAULT_POLL_SECONDS :: 60
MIN_POLL_SECONDS :: 10

// A poll fetches at most this many mails; the rest wait for the next.
@(private = "file")
POLL_MAILS_MOST :: 50
// Mails the loop hasn't taken yet. With this many, polls wait.
@(private = "file")
INBOX_MOST :: 256
// What may wait to be sent or deleted.
@(private = "file")
JOBS_MOST :: 64
// The most of a mail's header that's read; the rest is dropped.
@(private = "file")
HEADER_MOST :: 64 * 1024
// Seconds libcurl gets to connect, and for a whole exchange.
@(private = "file")
CONNECT_TIMEOUT :: 15
@(private = "file")
EXCHANGE_TIMEOUT :: 60

// Mail is a mail that has come in, as the loop is given it. Its strings
// are its own (mail_destroy).
Mail :: struct {
	uid:          u32, // its IMAP UID, for email_delete
	from:         string, // the address alone, in lower case; "" if none could be read
	subject:      string, // decoded (RFC 2047)
	date:         string, // as it was written
	auth_results: []string, // the Authentication-Results headers, unfolded
}

mail_destroy :: proc(m: ^Mail) {
	delete(m.from)
	delete(m.subject)
	delete(m.date)
	for r in m.auth_results {
		delete(r)
	}
	delete(m.auth_results)
	m^ = {}
}

@(private = "file")
Email_Job :: struct {
	delete:  bool, // delete mail `uid`; otherwise send
	uid:     u32,
	to:      string,
	subject: string,
	body:    string,
}

Email :: struct {
	enabled: bool, // configured, and libcurl is there
	config:  Email_Config,
	curl:    Curl,
	thread:  ^thread.Thread,
	mutex:   sync.Mutex,
	wake:    sync.Cond,
	stop:    bool,
	poll:    bool, // poll now rather than when it's due
	jobs:    [dynamic]Email_Job,
	inbox:   [dynamic]Mail,
	// The thread's: its handle for IMAP, kept so the connection is too,
	// and whether the last try at each failed, so a failure is logged
	// once rather than every poll.
	imap:         Curl_Handle,
	imap_failing: bool,
	smtp_failing: bool,
}

/*
email_open starts the email thread, if the config has an address and
libcurl is to be had. Without either, the server runs without email:
email_send and email_delete do nothing and email_poll has nothing.
*/
email_open :: proc(e: ^Email, config: Email_Config) {
	if config.address == "" {
		return
	}
	if !curl_load(&e.curl) {
		log.warn("email is off")
		return
	}
	e.config = email_config_clone(config)
	e.enabled = true
	e.thread = thread.create_and_start_with_poly_data(e, email_run, init_context = context)
	log.infof("email as %s, reading %s every %d s", config.address, config.imap, config.poll_seconds)
}

email_close :: proc(e: ^Email) {
	if e.thread != nil {
		sync.lock(&e.mutex)
		e.stop = true
		sync.cond_signal(&e.wake)
		sync.unlock(&e.mutex)
		thread.join(e.thread)
		thread.destroy(e.thread)
	}
	for &job in e.jobs {
		email_job_destroy(&job)
	}
	delete(e.jobs)
	for &m in e.inbox {
		mail_destroy(&m)
	}
	delete(e.inbox)
	email_config_destroy(&e.config)
	e^ = {}
}

/*
email_send queues a mail to `to`, from the server's address. False if
there's no sending (no email, or no SMTP), the address or subject can't
be, or too much is waiting already.
*/
email_send :: proc(e: ^Email, to, subject, body: string) -> bool {
	if !e.enabled || e.config.smtp == "" {
		return false
	}
	buf: [proto.MAX_EMAIL_SIZE]u8
	address, ok := proto.email_clean(to, &buf)
	if !ok || strings.contains_any(subject, "\r\n") {
		return false
	}
	return email_queue(
		e,
		{
			to = strings.clone(address),
			subject = strings.clone(subject),
			body = strings.clone(body),
		},
	)
}

// email_delete has a mail that came in (Mail.uid) deleted from the
// mailbox.
email_delete :: proc(e: ^Email, uid: u32) -> bool {
	return e.enabled && email_queue(e, {delete = true, uid = uid})
}

// email_check_now has the mailbox looked at now rather than at the next
// poll.
email_check_now :: proc(e: ^Email) {
	if !e.enabled {
		return
	}
	sync.guard(&e.mutex)
	e.poll = true
	sync.cond_signal(&e.wake)
}

// email_poll takes the oldest mail that has come in, if there is one;
// the caller owns it (mail_destroy).
@(require_results)
email_poll :: proc(e: ^Email) -> (m: Mail, ok: bool) {
	if !e.enabled {
		return
	}
	sync.guard(&e.mutex)
	if len(e.inbox) == 0 {
		return
	}
	m = e.inbox[0]
	ordered_remove(&e.inbox, 0)
	return m, true
}

/*
email_sync gives the loop what has come in. Nothing reads the server's
mail yet (verifying addresses will, docs/next item 8), so it's only
logged; it stays in the mailbox, seen.
*/
email_sync :: proc(s: ^Server) {
	for {
		m := email_poll(&s.email) or_break
		log.debugf("mail %d from %q: %q", m.uid, m.from, m.subject)
		mail_destroy(&m)
	}
}

@(private = "file")
email_queue :: proc(e: ^Email, job: Email_Job) -> bool {
	job := job
	sync.guard(&e.mutex)
	if len(e.jobs) >= JOBS_MOST {
		email_job_destroy(&job)
		return false
	}
	append(&e.jobs, job)
	sync.cond_signal(&e.wake)
	return true
}

@(private = "file")
email_job_destroy :: proc(job: ^Email_Job) {
	delete(job.to)
	delete(job.subject)
	delete(job.body)
}

@(private = "file")
email_config_clone :: proc(c: Email_Config) -> Email_Config {
	out := c
	out.address = strings.clone(c.address)
	out.imap = strings.clone(c.imap)
	out.smtp = strings.clone(c.smtp)
	out.username = strings.clone(c.username)
	out.password = strings.clone(c.password)
	out.trusted_auth_host = strings.clone(c.trusted_auth_host)
	return out
}

@(private = "file")
email_config_destroy :: proc(c: ^Email_Config) {
	delete(c.address)
	delete(c.imap)
	delete(c.smtp)
	delete(c.username)
	delete(c.password)
	delete(c.trusted_auth_host)
}

// email_run is the email thread: jobs as they come, and the mailbox
// every poll_seconds.
@(private = "file")
email_run :: proc(e: ^Email) {
	every := time.Duration(e.config.poll_seconds) * time.Second
	next_poll := time.tick_now()
	jobs := make([dynamic]Email_Job)
	defer delete(jobs)
	e.imap = e.curl.easy_init()
	defer if e.imap != nil {
		e.curl.easy_cleanup(e.imap)
	}
	for {
		free_all(context.temp_allocator)
		poll := false
		{
			sync.guard(&e.mutex)
			for !e.stop && len(e.jobs) == 0 && !e.poll {
				wait := time.tick_diff(time.tick_now(), next_poll)
				if wait <= 0 {
					break
				}
				sync.cond_wait_with_timeout(&e.wake, &e.mutex, wait)
			}
			if e.stop {
				return
			}
			due := e.poll || time.tick_diff(time.tick_now(), next_poll) <= 0
			poll = due && len(e.inbox) < INBOX_MOST
			if due {
				e.poll = false
			}
			append(&jobs, ..e.jobs[:])
			clear(&e.jobs)
		}
		for &job in jobs {
			if job.delete {
				imap_delete(e, job.uid)
			} else {
				smtp_send(e, job.to, job.subject, job.body)
			}
			email_job_destroy(&job)
		}
		clear(&jobs)
		if poll {
			imap_poll(e)
			next_poll = time.tick_add(time.tick_now(), every)
		}
	}
}

// imap_poll queues for the loop the mails it hasn't seen yet.
@(private = "file")
imap_poll :: proc(e: ^Email) {
	box := fmt.tprintf("%s/INBOX", url_base(e.config.imap))
	found := make([dynamic]u8, context.temp_allocator)
	if !email_report(e, true, curl_request(e, e.imap, box, custom = "UID SEARCH UNSEEN", out = &found)) {
		return
	}
	uids := imap_search_uids(string(found[:]))
	for uid in uids[:min(len(uids), POLL_MAILS_MOST)] {
		header := make([dynamic]u8, context.temp_allocator)
		url := fmt.tprintf("%s/;UID=%d/;SECTION=HEADER", box, uid)
		if !email_report(e, true, curl_request(e, e.imap, url, out = &header)) {
			return
		}
		m := mail_parse(uid, string(header[:]))
		sync.guard(&e.mutex)
		append(&e.inbox, m)
	}
}

@(private = "file")
imap_delete :: proc(e: ^Email, uid: u32) {
	box := fmt.tprintf("%s/INBOX", url_base(e.config.imap))
	store := fmt.tprintf("UID STORE %d +FLAGS.SILENT (\\Deleted)", uid)
	if email_report(e, true, curl_request(e, e.imap, box, custom = store)) {
		email_report(e, true, curl_request(e, e.imap, box, custom = "EXPUNGE"))
	}
}

@(private = "file")
smtp_send :: proc(e: ^Email, to, subject, body: string) {
	message := mail_compose(e.config.address, to, subject, body, time.now())
	err := curl_request(
		e,
		nil,
		url_base(e.config.smtp),
		mail_from = e.config.address,
		mail_to = to,
		upload = transmute([]u8)message,
	)
	if email_report(e, false, err) {
		log.infof("mailed %s: %q", to, subject)
	}
}

/*
email_report logs how a try at the mail server went, `imap` or SMTP's:
a failure when it's the first in a row, and that it works again after
one. It says whether this one worked.
*/
@(private = "file")
email_report :: proc(e: ^Email, imap: bool, err: string) -> bool {
	failing := &e.imap_failing if imap else &e.smtp_failing
	what := "IMAP" if imap else "SMTP"
	if err != "" {
		if !failing^ {
			log.warnf("email: %s failed: %s", what, err)
		}
		failing^ = true
		return false
	}
	if failing^ {
		log.infof("email: %s works again", what)
	}
	failing^ = false
	return true
}

// ---- libcurl ----

@(private = "file")
Curl_Sink :: struct {
	ctx:  runtime.Context,
	data: ^[dynamic]u8, // nil: thrown away
}

@(private = "file")
Curl_Source :: struct {
	data: []u8,
	pos:  int,
}

@(private = "file")
curl_write :: proc "c" (data: [^]u8, size, count: uint, user: rawptr) -> uint {
	sink := (^Curl_Sink)(user)
	context = sink.ctx
	n := int(size * count)
	if sink.data != nil && len(sink.data) + n <= HEADER_MOST {
		append(sink.data, ..data[:n])
	}
	return uint(n)
}

@(private = "file")
curl_read :: proc "c" (data: [^]u8, size, count: uint, user: rawptr) -> uint {
	src := (^Curl_Source)(user)
	n := copy(data[:size * count], src.data[src.pos:])
	src.pos += n
	return uint(n)
}

/*
curl_request does one exchange with a mail server, on `h` (which keeps
its connection for the next) or with no handle given on one of its own:
for IMAP the URL's mailbox and message and `custom` command, with
what comes back into `out`; for SMTP, `upload` from `mail_from` to
`mail_to`. It returns what went wrong, "" if nothing did.
*/
curl_request :: proc(
	e: ^Email,
	h: Curl_Handle,
	url: string,
	custom := "",
	out: ^[dynamic]u8 = nil,
	mail_from := "",
	mail_to := "",
	upload: []u8 = nil,
	no_body := false,
) -> string {
	c := &e.curl
	h := h
	if h == nil {
		h = c.easy_init()
		if h == nil {
			return "libcurl could not make a handle"
		}
	} else {
		c.easy_reset(h)
	}
	defer if h != e.imap {
		c.easy_cleanup(h)
	}
	tc :: proc(s: string) -> cstring {
		return strings.clone_to_cstring(s, context.temp_allocator)
	}
	errors: [CURL_ERROR_SIZE]u8
	sink := Curl_Sink{context, out}
	source := Curl_Source{data = upload}
	user := e.config.username if e.config.username != "" else e.config.address
	c.easy_setopt(h, .Url, tc(url))
	c.easy_setopt(h, .Username, tc(user))
	c.easy_setopt(h, .Password, tc(e.config.password))
	c.easy_setopt(h, .Use_Ssl, tls_wanted(url))
	c.easy_setopt(h, .Connect_Timeout, int(CONNECT_TIMEOUT))
	c.easy_setopt(h, .Timeout, int(EXCHANGE_TIMEOUT))
	c.easy_setopt(h, .No_Signal, int(1))
	c.easy_setopt(h, .Error_Buffer, raw_data(errors[:]))
	c.easy_setopt(h, .Write_Function, curl_write)
	c.easy_setopt(h, .Write_Data, &sink)
	if custom != "" {
		c.easy_setopt(h, .Custom_Request, tc(custom))
	}
	if no_body {
		c.easy_setopt(h, .No_Body, int(1))
	}
	rcpt: Curl_Slist
	defer if rcpt != nil {
		c.slist_free_all(rcpt)
	}
	if mail_from != "" {
		rcpt = c.slist_append(nil, tc(fmt.tprintf("<%s>", mail_to)))
		c.easy_setopt(h, .Mail_From, tc(fmt.tprintf("<%s>", mail_from)))
		c.easy_setopt(h, .Mail_Rcpt, rcpt)
		c.easy_setopt(h, .Upload, int(1))
		c.easy_setopt(h, .Read_Function, curl_read)
		c.easy_setopt(h, .Read_Data, &source)
	}
	if code := c.easy_perform(h); code != 0 {
		if errors[0] != 0 {
			return strings.clone(string(cstring(raw_data(errors[:]))), context.temp_allocator)
		}
		return strings.clone(string(c.easy_strerror(code)), context.temp_allocator)
	}
	return ""
}

// url_base is a server's URL without a trailing slash.
url_base :: proc(url: string) -> string {
	return strings.trim_right(url, "/")
}

/*
tls_wanted is CURLOPT_USE_SSL for a URL: TLS from the start for imaps://
and smtps://, and otherwise STARTTLS, which only a server on this
machine may go without.
*/
@(private = "file")
tls_wanted :: proc(url: string) -> int {
	rest := url[strings.index(url, "://") + 3:] if strings.contains(url, "://") else url
	host := rest
	if i := strings.index_any(rest, ":/"); i >= 0 {
		host = rest[:i]
	}
	if host == "localhost" || strings.has_prefix(host, "127.") || strings.has_prefix(rest, "[::1]") {
		return CURL_USESSL_TRY
	}
	return CURL_USESSL_ALL
}

// ---- reading mail ----

// imap_search_uids reads the UIDs out of a SEARCH response
// ("* SEARCH 4 7 9"), into the temp allocator.
imap_search_uids :: proc(response: string) -> []u32 {
	uids := make([dynamic]u32, context.temp_allocator)
	response := response
	for raw in strings.split_lines_iterator(&response) {
		line := strings.trim_space(raw)
		if !strings.has_prefix(strings.to_upper(line, context.temp_allocator), "* SEARCH") {
			continue
		}
		for field in strings.fields(line[len("* SEARCH"):], context.temp_allocator) {
			if uid, ok := strconv.parse_uint(field, 10); ok && uid > 0 && uid <= uint(max(u32)) {
				append(&uids, u32(uid))
			}
		}
	}
	return uids[:]
}

/*
mail_parse reads what's wanted out of a mail's header: its lines,
unfolded, up to the first empty one. What it returns is its own.
*/
mail_parse :: proc(uid: u32, header: string) -> Mail {
	m := Mail {
		uid = uid,
	}
	results := make([dynamic]string)
	// Unfolded, a header at a time: a line starting with a space or a
	// tab carries on the one before.
	fields := make([dynamic]string, context.temp_allocator)
	rest := header
	for raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_right(raw, "\r")
		if line == "" {
			break
		}
		if (line[0] == ' ' || line[0] == '\t') && len(fields) > 0 {
			last := &fields[len(fields) - 1]
			last^ = strings.concatenate({last^, " ", strings.trim_space(line)}, context.temp_allocator)
			continue
		}
		append(&fields, line)
	}
	for field in fields {
		colon := strings.index_byte(field, ':')
		if colon <= 0 {
			continue
		}
		name := strings.trim_space(field[:colon])
		value := strings.trim_space(field[colon + 1:])
		switch {
		case strings.equal_fold(name, "From") && m.from == "":
			m.from = address_of(value)
		case strings.equal_fold(name, "Subject") && m.subject == "":
			m.subject = decode_words(value)
		case strings.equal_fold(name, "Date") && m.date == "":
			m.date = strings.clone(value)
		case strings.equal_fold(name, "Authentication-Results"):
			append(&results, strings.clone(value))
		}
	}
	m.auth_results = results[:]
	if m.from == "" {
		m.from = strings.clone("")
	}
	if m.subject == "" {
		m.subject = strings.clone("")
	}
	if m.date == "" {
		m.date = strings.clone("")
	}
	return m
}

/*
address_of is the address in a From: the one in <angle brackets>, or
the whole of it; in lower case, and "" if that's no address. Its own.
*/
address_of :: proc(from: string) -> string {
	raw := from
	if open := strings.last_index_byte(from, '<'); open >= 0 {
		if close := strings.index_byte(from[open:], '>'); close > 0 {
			raw = from[open + 1:open + close]
		}
	}
	buf: [proto.MAX_EMAIL_SIZE]u8
	address, ok := proto.email_clean(raw, &buf)
	return strings.clone(address if ok else "")
}

/*
decode_words decodes a header's RFC 2047 encoded words
("=?UTF-8?B?...?=", "=?UTF-8?Q?...?="), dropping the space between two
of them as the RFC says. The charset is taken to be UTF-8 or ASCII,
which is what anything sends now; bytes that aren't UTF-8 are kept as
they are. Anything that isn't an encoded word is copied. Its own.
*/
decode_words :: proc(value: string) -> string {
	b := strings.builder_make()
	rest := value
	after_word := false // what was written last was an encoded word
	for len(rest) > 0 {
		start := strings.index(rest, "=?")
		if start < 0 {
			strings.write_string(&b, rest)
			break
		}
		decoded, used, ok := decode_word(rest[start:])
		if !ok {
			strings.write_string(&b, rest[:start + 2])
			rest = rest[start + 2:]
			after_word = false
			continue
		}
		// White space between two encoded words goes.
		before := rest[:start]
		if !after_word || strings.trim_space(before) != "" {
			strings.write_string(&b, before)
		}
		strings.write_string(&b, decoded)
		rest = rest[start + used:]
		after_word = true
	}
	return strings.to_string(b)
}

// decode_word decodes the encoded word `s` starts with, into the temp
// allocator, and says how many bytes of `s` it was.
@(private = "file")
decode_word :: proc(s: string) -> (decoded: string, used: int, ok: bool) {
	// =?charset?enc?text?=
	q1 := strings.index_byte(s[2:], '?')
	if q1 < 0 {
		return
	}
	q1 += 2
	if q1 + 2 >= len(s) || s[q1 + 2] != '?' {
		return
	}
	encoding := s[q1 + 1]
	text_start := q1 + 3
	end := strings.index(s[text_start:], "?=")
	if end < 0 {
		return
	}
	text := s[text_start:text_start + end]
	used = text_start + end + 2
	switch encoding {
	case 'B', 'b':
		bytes, err := base64.decode(text, allocator = context.temp_allocator)
		if err != nil {
			return
		}
		return string(bytes), used, true
	case 'Q', 'q':
		out := make([dynamic]u8, 0, len(text), context.temp_allocator)
		for i := 0; i < len(text); i += 1 {
			switch text[i] {
			case '_':
				append(&out, ' ')
			case '=':
				if i + 2 >= len(text) {
					return
				}
				v, hex_ok := hex.decode_sequence(text[i + 1:i + 3])
				if !hex_ok {
					return
				}
				append(&out, v)
				i += 2
			case:
				append(&out, text[i])
			}
		}
		return string(out[:]), used, true
	}
	return
}

// ---- writing mail ----

/*
mail_compose writes a plain text mail from `from` to `to`, with CRLF
line ends as SMTP wants; a subject that isn't ASCII is encoded
(RFC 2047). Into the temp allocator.
*/
mail_compose :: proc(from, to, subject, body: string, now: time.Time) -> string {
	b := strings.builder_make(context.temp_allocator)
	id: [16]u8
	crypto.rand_bytes(id[:])
	domain := from[strings.index_byte(from, '@') + 1:]
	fmt.sbprintf(&b, "Date: %s\r\n", rfc5322_date(now))
	fmt.sbprintf(&b, "From: <%s>\r\n", from)
	fmt.sbprintf(&b, "To: <%s>\r\n", to)
	fmt.sbprintf(&b, "Subject: %s\r\n", encode_subject(subject))
	fmt.sbprintf(&b, "Message-ID: <%s@%s>\r\n", hex.encode(id[:], context.temp_allocator), domain)
	strings.write_string(&b, "MIME-Version: 1.0\r\n")
	strings.write_string(&b, "Content-Type: text/plain; charset=utf-8\r\n")
	strings.write_string(&b, "Content-Transfer-Encoding: 8bit\r\n\r\n")
	rest := body
	for line in strings.split_lines_iterator(&rest) {
		strings.write_string(&b, strings.trim_right(line, "\r"))
		strings.write_string(&b, "\r\n")
	}
	return strings.to_string(b)
}

// encode_subject is a subject as a header may carry it: as it is if
// it's ASCII, else as encoded words of at most 45 bytes each.
@(private = "file")
encode_subject :: proc(subject: string) -> string {
	ascii := true
	for i in 0 ..< len(subject) {
		if subject[i] >= 0x80 || subject[i] < 0x20 {
			ascii = false
			break
		}
	}
	if ascii {
		return subject
	}
	b := strings.builder_make(context.temp_allocator)
	rest := subject
	for len(rest) > 0 {
		// Whole characters only.
		n := min(45, len(rest))
		for n < len(rest) && !utf8.rune_start(rest[n]) {
			n -= 1
		}
		if strings.builder_len(b) > 0 {
			strings.write_string(&b, "\r\n ")
		}
		encoded, _ := base64.encode(transmute([]u8)rest[:n], allocator = context.temp_allocator)
		fmt.sbprintf(&b, "=?UTF-8?B?%s?=", encoded)
		rest = rest[n:]
	}
	return strings.to_string(b)
}

// rfc5322_date is a time as a Date header has it, in UTC.
rfc5322_date :: proc(t: time.Time) -> string {
	DAYS :: [7]string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}
	MONTHS :: [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
	year, month, day := time.date(t)
	hour, minute, second := time.clock_from_time(t)
	days := DAYS
	months := MONTHS
	return fmt.tprintf(
		"%s, %02d %s %d %02d:%02d:%02d +0000",
		days[int(time.weekday(t))],
		day,
		months[int(month) - 1],
		year,
		hour,
		minute,
		second,
	)
}
