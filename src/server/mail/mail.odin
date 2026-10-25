package mail

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

import "../curl"
import "common:memtrack"
import "common:proto"

// The server's own email account (config.json's "email", see config.odin).
// It reads incoming mail over IMAP and sends mail over SMTP, both through
// libcurl (curl.odin). Incoming mail is used to verify the email addresses of
// accounts (verify.odin). Outgoing mail tells accounts what they missed while
// they were away (digest.odin) and will also be used for password resets.
//
// Message is slow and can hang, so all of it runs on a thread of its own. The
// main loop talks to that thread through two queues, like it does with the
// password hasher (hash_worker.odin):
//
// - Every poll_seconds, and whenever it is asked to, the thread searches the
//   INBOX for mails that haven't been seen yet (UID SEARCH UNSEEN). It fetches
//   the header of each one, which marks it as seen, and queues it for the
//   main loop as a Message containing the sender, subject, date and
//   Authentication-Results. The main loop takes them with poll.
// - The main loop queues the work that should be done: sending a mail
//   (send) or deleting a mail it has finished with (delete_mail).
//
// The main loop never waits for any of this. If the mail server can't be
// reached, this is logged when it starts failing and when it works again, and
// the connection is retried at the next poll.
//
// The addresses in the config are URLs. imaps:// and smtps:// connect with TLS.
// imap:// and smtp:// are upgraded with STARTTLS, which a remote server must
// offer so that the password is never sent in the clear. A server on this
// machine (localhost, 127.x) may do without it.

Config :: struct {
	address:            string, // the server's address, empty if email is disabled
	imap:               string, // imaps://host[:port]
	smtp:               string, // smtps://host[:port], empty if sending is disabled
	username:           string, // defaults to the address if empty
	password:           string,
	poll_seconds:       int,
	// Whether a verification mail must be proven to come from the address in
	// its From header. The proof is the Authentication-Results header added by
	// trusted_auth_host (verify.odin), since the headers of other hosts can't
	// be trusted.
	check_auth_results: bool,
	trusted_auth_host:  string,
	// How long an account has to be away before it is mailed what it
	// missed, and the minimum time between two such mails (digest.odin).
	digest_minutes:     int,
}

DEFAULT_POLL_SECONDS :: 60
MIN_POLL_SECONDS :: 10
DEFAULT_DIGEST_MINUTES :: 30
MIN_DIGEST_MINUTES :: 5

// A poll fetches at most this many mails. The rest wait for the next poll.
@(private = "file")
POLL_MAILS_MOST :: 50
// The maximum number of mails the main loop hasn't taken yet. Polling pauses
// while the inbox queue is this full.
@(private = "file")
INBOX_MOST :: 256
// The maximum number of jobs waiting to be sent or deleted.
@(private = "file")
JOBS_MOST :: 64
// The maximum number of bytes read from a mail's header. The rest is dropped.
@(private = "file")
HEADER_MOST :: 64 * 1024
// The time in seconds libcurl gets to connect and to complete a whole exchange.
@(private = "file")
CONNECT_TIMEOUT :: 15
@(private = "file")
EXCHANGE_TIMEOUT :: 60

// Message is a mail that has come in, as it is handed to the main loop. It owns
// its strings (see message_destroy).
Message :: struct {
	uid:          u32, // its IMAP UID, used by delete_mail
	from:         string, // only the address, in lower case, or "" if none could be read
	subject:      string, // decoded (RFC 2047)
	date:         string, // as written in the header
	auth_results: []string, // the Authentication-Results headers, unfolded
}

message_destroy :: proc(m: ^Message) {
	delete(m.from)
	delete(m.subject)
	delete(m.date)
	for r in m.auth_results {
		delete(r)
	}
	delete(m.auth_results)
	m^ = {}
}

// Job is a job the main loop has queued for the email thread.
Job :: struct {
	delete:  bool, // delete mail `uid` instead of sending
	uid:     u32,
	to:      string,
	subject: string,
	body:    string,
}

Mailer :: struct {
	enabled:      bool, // configured and libcurl is available
	config:       Config,
	lib:          curl.Lib,
	thread:       ^thread.Thread,
	mutex:        sync.Mutex,
	wake:         sync.Cond,
	stop:         bool,
	poll:         bool, // poll now instead of when it is due
	jobs:         [dynamic]Job,
	inbox:        [dynamic]Message,
	// Owned by the email thread: its IMAP handle, which is kept so the
	// connection can be reused, and whether the last attempt of each protocol
	// failed so that a failure is only logged once instead of at every poll.
	imap:         curl.Handle,
	imap_failing: bool,
	smtp_failing: bool,
}

// open starts the email thread if the config has an address and
// libcurl is available. Without either, the server runs without email:
// send and delete_mail do nothing and poll never returns a mail.
open :: proc(e: ^Mailer, config: Config) {
	if config.address == "" {
		return
	}
	if !curl.load(&e.lib) {
		log.warn("email is disabled because libcurl could not be loaded")
		return
	}
	e.config = config_clone(config)
	e.enabled = true
	e.thread = thread.create_and_start_with_poly_data(e, run, init_context = context)
	log.infof(
		"email as %s, reading %s every %d s",
		config.address,
		config.imap,
		config.poll_seconds,
	)
}

close :: proc(e: ^Mailer) {
	if e.thread != nil {
		sync.lock(&e.mutex)
		e.stop = true
		sync.cond_signal(&e.wake)
		sync.unlock(&e.mutex)
		thread.join(e.thread)
		thread.destroy(e.thread)
	}
	for &job in e.jobs {
		job_destroy(&job)
	}
	delete(e.jobs)
	for &m in e.inbox {
		message_destroy(&m)
	}
	delete(e.inbox)
	config_destroy(&e.config)
	e^ = {}
}

// send queues a mail to `to`, sent from the server's address. It returns
// false if sending is disabled (no email or no SMTP), the address or subject
// is invalid, or too many jobs are already waiting.
send :: proc(e: ^Mailer, to, subject, body: string) -> bool {
	if !e.enabled || e.config.smtp == "" {
		return false
	}
	buf: [proto.MAX_EMAIL_SIZE]u8
	address, ok := proto.email_clean(to, &buf)
	if !ok || strings.contains_any(subject, "\r\n") {
		return false
	}
	return queue(
		e,
		{
			to = strings.clone(address),
			subject = strings.clone(subject),
			body = strings.clone(body),
		},
	)
}

// delete_mail queues the deletion of a mail that came in (see Message.uid) from
// the mailbox.
delete_mail :: proc(e: ^Mailer, uid: u32) -> bool {
	return e.enabled && queue(e, {delete = true, uid = uid})
}

// check_now polls the mailbox right away instead of at the next
// scheduled poll.
check_now :: proc(e: ^Mailer) {
	if !e.enabled {
		return
	}
	sync.guard(&e.mutex)
	e.poll = true
	sync.cond_signal(&e.wake)
}

// poll takes the oldest mail that has come in, if there is one.
// The caller owns it and must free it with message_destroy.
@(require_results)
poll :: proc(e: ^Mailer) -> (m: Message, ok: bool) {
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

@(private = "file")
queue :: proc(e: ^Mailer, job: Job) -> bool {
	job := job
	sync.guard(&e.mutex)
	if len(e.jobs) >= JOBS_MOST {
		job_destroy(&job)
		return false
	}
	append(&e.jobs, job)
	sync.cond_signal(&e.wake)
	return true
}

@(private = "file")
job_destroy :: proc(job: ^Job) {
	delete(job.to)
	delete(job.subject)
	delete(job.body)
}

@(private = "file")
config_clone :: proc(c: Config) -> Config {
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
config_destroy :: proc(c: ^Config) {
	delete(c.address)
	delete(c.imap)
	delete(c.smtp)
	delete(c.username)
	delete(c.password)
	delete(c.trusted_auth_host)
}

// run is the email thread. It handles jobs as they arrive and polls the
// mailbox every poll_seconds.
@(private = "file")
run :: proc(e: ^Mailer) {
	memtrack.thread_init()
	every := time.Duration(e.config.poll_seconds) * time.Second
	next_poll := time.tick_now()
	jobs := make([dynamic]Job)
	defer delete(jobs)
	e.imap = e.lib.easy_init()
	defer if e.imap != nil {
		e.lib.easy_cleanup(e.imap)
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
			job_destroy(&job)
		}
		clear(&jobs)
		if poll {
			imap_poll(e)
			next_poll = time.tick_add(time.tick_now(), every)
		}
	}
}

// imap_poll queues all unseen mails for the main loop.
@(private = "file")
imap_poll :: proc(e: ^Mailer) {
	box := fmt.tprintf("%s/INBOX", url_base(e.config.imap))
	found := make([dynamic]u8, context.temp_allocator)
	if !report(e, true, curl_request(e, e.imap, box, custom = "UID SEARCH UNSEEN", out = &found)) {
		return
	}
	uids := imap_search_uids(string(found[:]))
	for uid in uids[:min(len(uids), POLL_MAILS_MOST)] {
		header := make([dynamic]u8, context.temp_allocator)
		url := fmt.tprintf("%s/;UID=%d/;SECTION=HEADER", box, uid)
		if !report(e, true, curl_request(e, e.imap, url, out = &header)) {
			return
		}
		m := parse(uid, string(header[:]))
		sync.guard(&e.mutex)
		append(&e.inbox, m)
	}
}

@(private = "file")
imap_delete :: proc(e: ^Mailer, uid: u32) {
	box := fmt.tprintf("%s/INBOX", url_base(e.config.imap))
	store := fmt.tprintf("UID STORE %d +FLAGS.SILENT (\\Deleted)", uid)
	if report(e, true, curl_request(e, e.imap, box, custom = store)) {
		report(e, true, curl_request(e, e.imap, box, custom = "EXPUNGE"))
	}
}

@(private = "file")
smtp_send :: proc(e: ^Mailer, to, subject, body: string) {
	message := compose(e.config.address, to, subject, body, time.now())
	err := curl_request(
		e,
		nil,
		url_base(e.config.smtp),
		mail_from = e.config.address,
		mail_to = to,
		upload = transmute([]u8)message,
	)
	if report(e, false, err) {
		log.infof("mailed %s: %q", to, subject)
	}
}

// report logs the outcome of a request to the mail server (IMAP if
// `imap` is set, otherwise SMTP). It logs the first failure in a row and when
// the server works again afterwards. It returns whether the request worked.
@(private = "file")
report :: proc(e: ^Mailer, imap: bool, err: string) -> bool {
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
	data: ^[dynamic]u8, // if nil, the data is discarded
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

// curl_request performs one exchange with a mail server. It uses the handle
// `h`, which keeps its connection for the next request, or a temporary handle
// if none is given. For IMAP it requests the URL's mailbox and message, runs
// the `custom` command and stores the response in `out`. For SMTP it uploads
// `upload` from `mail_from` to `mail_to`. It returns the error message, or ""
// if the exchange succeeded.
curl_request :: proc(
	e: ^Mailer,
	h: curl.Handle,
	url: string,
	custom := "",
	out: ^[dynamic]u8 = nil,
	mail_from := "",
	mail_to := "",
	upload: []u8 = nil,
	no_body := false,
) -> string {
	c := &e.lib
	h := h
	if h == nil {
		h = c.easy_init()
		if h == nil {
			return "libcurl could not create a handle"
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
	errors: [curl.ERROR_SIZE]u8
	sink := Curl_Sink{context, out}
	source := Curl_Source {
		data = upload,
	}
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
	rcpt: curl.Slist
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

// url_base returns a server's URL without a trailing slash.
url_base :: proc(url: string) -> string {
	return strings.trim_right(url, "/")
}

// tls_wanted returns the CURLOPT_USE_SSL value for a URL. It requires TLS from
// the start for imaps:// and smtps:// and STARTTLS otherwise. Only a server
// on this machine may go without STARTTLS.
@(private = "file")
tls_wanted :: proc(url: string) -> int {
	rest := url[strings.index(url, "://") + 3:] if strings.contains(url, "://") else url
	host := rest
	if i := strings.index_any(rest, ":/"); i >= 0 {
		host = rest[:i]
	}
	if host == "localhost" ||
	   strings.has_prefix(host, "127.") ||
	   strings.has_prefix(rest, "[::1]") {
		return curl.USESSL_TRY
	}
	return curl.USESSL_ALL
}

// ---- reading mail ----

// imap_search_uids reads the UIDs from a SEARCH response ("* SEARCH 4 7 9")
// and returns them in a slice allocated with the temp allocator.
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

// parse extracts the relevant fields from a mail's header, which is read
// up to the first empty line, with folded lines joined. The returned Message owns
// its strings.
parse :: proc(uid: u32, header: string) -> Message {
	m := Message {
		uid = uid,
	}
	results := make([dynamic]string)
	// Unfold the headers: a line that starts with a space or a tab continues
	// the previous line.
	fields := make([dynamic]string, context.temp_allocator)
	rest := header
	for raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_right(raw, "\r")
		if line == "" {
			break
		}
		if (line[0] == ' ' || line[0] == '\t') && len(fields) > 0 {
			last := &fields[len(fields) - 1]
			last^ = strings.concatenate(
				{last^, " ", strings.trim_space(line)},
				context.temp_allocator,
			)
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

// address_of returns the address from a From header, which is either the part
// in <angle brackets> or the whole value. The result is in lower case, or ""
// if the value isn't a valid address. The caller owns the returned string.
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

// decode_words decodes the RFC 2047 encoded words in a header value
// ("=?UTF-8?B?...?=", "=?UTF-8?Q?...?="). As the RFC specifies, whitespace
// between two encoded words is dropped. The charset is assumed to be UTF-8 or
// ASCII, which is what practically all mail uses today. Bytes that aren't
// valid UTF-8 are kept as they are, and text outside of encoded words is
// copied unchanged. The caller owns the returned string.
decode_words :: proc(value: string) -> string {
	b := strings.builder_make()
	rest := value
	after_word := false // whether the last thing written was an encoded word
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
		// Drop whitespace between two encoded words.
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

// decode_word decodes the encoded word at the start of `s` using the temp
// allocator and returns how many bytes of `s` it used.
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

// compose writes a plain text mail from `from` to `to` using CRLF line
// endings as SMTP requires. A subject that isn't ASCII is encoded as described
// in RFC 2047. The result is allocated with the temp allocator.
compose :: proc(from, to, subject, body: string, now: time.Time) -> string {
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

// encode_subject returns the subject in a form that a header can carry. ASCII
// subjects are returned unchanged, others are split into encoded words of at
// most 45 bytes each.
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
		// Only split between whole characters.
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

// rfc5322_date formats a time (in UTC) as it is written in a Date header.
rfc5322_date :: proc(t: time.Time) -> string {
	DAYS :: [7]string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}
	MONTHS :: [12]string {
		"Jan",
		"Feb",
		"Mar",
		"Apr",
		"May",
		"Jun",
		"Jul",
		"Aug",
		"Sep",
		"Oct",
		"Nov",
		"Dec",
	}
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
