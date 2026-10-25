package webpush

import "base:runtime"
import "core:c"
import "core:crypto/ecdsa"
import "core:fmt"
import "core:log"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "../curl"
import "common:memtrack"
import "common:proto"

// Web Pusher (docs/design/mobile.md): notifies browsers about new activity while the client isn't open,
// through the push service each browser uses (Google's, Mozilla's, Apple's).
//
// A subscribing browser is given this server's VAPID public key (Pusher.public) and receives
// an endpoint URL at its push service, plus two keys used to encrypt messages for it. To
// notify it, the server encrypts a small payload for it (crypto.odin) and POSTs it to
// the endpoint with libcurl, signed with the VAPID key. The push service delivers it to the
// browser, which shows it from its service worker (web/sw.js), whether or not the page is
// open.
//
// The POSTs are made on PUSH_WORKERS threads of their own, so a slow push service never
// blocks the main loop: send queues a job, and its result is returned by poll. An
// endpoint that answers 404 or 410 is gone for good, and its subscription should be deleted.
//
// Endpoints are chosen by users' browsers, or by a modified client, so they're treated with
// care:
//   - Only addresses on the public internet are connected to (address_public), checked
//     after the name is resolved. An endpoint elsewhere is gone for good.
//   - Redirects aren't followed, and the answer is only logged.
//   - An account has at most one push in progress, so endpoints that answer slowly can only
//     hold up one worker per account, and the other accounts' pushes go on.
//
// The key is the config's push.vapid_key, generated on the first run like the server's own
// key. Browsers subscribed using its public half, so changing it invalidates every
// existing subscription.

// The maximum number of queued jobs; once it's reached, further pushes are dropped.
@(private = "file")
PUSH_JOBS_MOST :: 1024
// Timeouts for a push in seconds: for connecting, and for the whole request.
@(private = "file")
PUSH_CONNECT_TIMEOUT :: 5
@(private = "file")
PUSH_TIMEOUT :: 10
// The number of threads that make the POSTs.
PUSH_WORKERS :: 4
// How long a VAPID token is valid, and how long before it expires a new one is created.
// Pusher services accept a lifetime of at most a day.
@(private = "file")
VAPID_LIFETIME :: 12 * time.Hour
@(private = "file")
VAPID_RENEW :: time.Hour
// How many bytes of a push service's response are kept, for logging.
@(private = "file")
PUSH_ANSWER_MOST :: 512

// The "push" section of the config.
Config :: struct {
	enabled:   bool,
	vapid_key: string,
	subject:   string,
}

// How urgently a push service should deliver a push (the Urgency header of RFC 8030).
Urgency :: enum u8 {
	Very_Low,
	Low,
	Normal,
	High,
}

@(private = "file")
URGENCY_NAMES := [Urgency]string {
	.Very_Low = "very-low",
	.Low      = "low",
	.Normal   = "normal",
	.High     = "high",
}

// Job is one message for one subscription. Its strings and slices are owned by the
// job.
Job :: struct {
	sub:      i64, // the subscription's id, returned with the result
	account:  proto.Account_Id, // the subscription's; 0 for none (the CLI's test push)
	endpoint: string,
	p256dh:   [P256_PUBLIC_SIZE]u8,
	auth:     [PUSH_AUTH_SIZE]u8,
	payload:  []u8,
	ttl:      int, // how many seconds the push service may hold on to it
	urgency:  Urgency,
	// A push with the same topic that is still waiting at the push service gets replaced
	// by this one; "" for no topic. At most 32 base64url characters.
	topic:    string,
}

Outcome :: enum u8 {
	Sent,
	Gone, // the subscription no longer exists (404, 410)
	Failed, // failed this time, but may work next time
}

Result :: struct {
	sub:     i64,
	outcome: Outcome,
}

Vapid_Token :: struct {
	jwt:     string,
	expires: time.Time,
}

Pusher :: struct {
	enabled: bool, // push is configured and libcurl was loaded
	key:     ecdsa.Private_Key,
	public:  [P256_PUBLIC_SIZE]u8,
	subject: string,
	lib:     curl.Lib,
	workers: [PUSH_WORKERS]Worker,
	mutex:   sync.Mutex,
	wake:    sync.Cond,
	stop:    bool,
	jobs:    [dynamic]Job,
	results: [dynamic]Result,
	// The accounts that have a push in progress, once for each.
	sending: [dynamic]proto.Account_Id,
	// The origins whose last push failed, so a failure is logged once rather than for
	// every push.
	failing: map[string]bool,
}

// Worker is one of the threads that make the POSTs. Its curl handle is kept alive so
// connections are reused, and it keeps the VAPID tokens it made, by push service origin.
@(private = "file")
Worker :: struct {
	push:   ^Pusher,
	thread: ^thread.Thread,
	handle: curl.Handle,
	tokens: map[string]Vapid_Token,
}

// open starts push, if it is enabled in the config and libcurl can be loaded.
// Otherwise send does nothing and Server_Info doesn't include a key, so clients don't
// offer push.
open :: proc(p: ^Pusher, config: Config) {
	if !config.enabled {
		log.info("push is disabled in the config")
		return
	}
	if !vapid_key_parse(config.vapid_key, &p.key) {
		log.error("push.vapid_key in the config is not a valid key, so push is disabled")
		return
	}
	if !curl.load(&p.lib, "push") {
		log.warn("push is disabled because libcurl couldn't be loaded")
		ecdsa.private_key_clear(&p.key)
		return
	}
	ecdsa.private_key_public_bytes(&p.key, p.public[:])
	p.subject = strings.clone(config.subject)
	p.enabled = true
	for &w in p.workers {
		w.push = p
		w.thread = thread.create_and_start_with_poly_data(&w, run, init_context = context)
	}
	log.infof("push enabled, with subject %s", config.subject)
}

close :: proc(p: ^Pusher) {
	sync.lock(&p.mutex)
	p.stop = true
	sync.cond_broadcast(&p.wake)
	sync.unlock(&p.mutex)
	for &w in p.workers {
		if w.thread != nil {
			thread.join(w.thread)
			thread.destroy(w.thread)
		}
	}
	for &job in p.jobs {
		job_destroy(&job)
	}
	delete(p.jobs)
	delete(p.results)
	delete(p.sending)
	for origin in p.failing {
		delete(origin)
	}
	delete(p.failing)
	delete(p.subject)
	ecdsa.private_key_clear(&p.key)
	p^ = {}
}

// send queues a message for a subscription; the job's strings and payload are copied.
// Returns false if push is disabled, the endpoint isn't a valid endpoint URL, the payload
// is too large, or the queue is full.
send :: proc(p: ^Pusher, job: Job) -> bool {
	if !p.enabled || origin(job.endpoint) == "" || len(job.payload) > PUSH_PAYLOAD_MOST {
		return false
	}
	job := job
	job.endpoint = strings.clone(job.endpoint)
	job.topic = strings.clone(job.topic)
	job.payload = clone_bytes(job.payload)
	sync.guard(&p.mutex)
	if len(p.jobs) >= PUSH_JOBS_MOST {
		job_destroy(&job)
		return false
	}
	append(&p.jobs, job)
	sync.cond_signal(&p.wake)
	return true
}

// poll returns the result of a finished push, if there is one.
@(require_results)
poll :: proc(p: ^Pusher) -> (r: Result, ok: bool) {
	if !p.enabled {
		return
	}
	sync.guard(&p.mutex)
	if len(p.results) == 0 {
		return
	}
	r = p.results[0]
	ordered_remove(&p.results, 0)
	return r, true
}

// waiting returns the number of queued jobs and of unread results, so tests and the
// CLI can wait for them.
waiting :: proc(p: ^Pusher) -> (jobs, results: int) {
	sync.guard(&p.mutex)
	return len(p.jobs) + len(p.sending), len(p.results)
}

// origin returns an endpoint's origin, "https://host[:port]", which is what its VAPID
// token is issued for; "" if it isn't an https:// URL with a path.
origin :: proc(endpoint: string) -> string {
	PREFIX :: "https://"
	if !strings.has_prefix(endpoint, PREFIX) || len(endpoint) > 2048 {
		return ""
	}
	rest := endpoint[len(PREFIX):]
	slash := strings.index_byte(rest, '/')
	if slash <= 0 {
		return ""
	}
	for ch in endpoint {
		if ch <= ' ' || ch > '~' || ch == '"' || ch == '\\' {
			return ""
		}
	}
	return endpoint[:len(PREFIX) + slash]
}

@(private = "file")
job_destroy :: proc(job: ^Job) {
	delete(job.endpoint)
	delete(job.topic)
	delete(job.payload)
}

@(private = "file")
clone_bytes :: proc(b: []u8) -> []u8 {
	out := make([]u8, len(b))
	copy(out, b)
	return out
}

// run is a push worker's main proc: it sends the queued jobs as they arrive, taking
// the oldest one whose account has no push in progress.
@(private = "file")
run :: proc(w: ^Worker) {
	memtrack.thread_init()
	p := w.push
	w.handle = p.lib.easy_init()
	defer {
		if w.handle != nil {
			p.lib.easy_cleanup(w.handle)
		}
		for origin, token in w.tokens {
			delete(origin)
			delete(token.jwt)
		}
		delete(w.tokens)
	}
	for {
		free_all(context.temp_allocator)
		job: Job
		{
			sync.guard(&p.mutex)
			next: for {
				if p.stop {
					return
				}
				for queued, i in p.jobs {
					if queued.account == 0 || !slice.contains(p.sending[:], queued.account) {
						job = queued
						ordered_remove(&p.jobs, i)
						append(&p.sending, job.account)
						break next
					}
				}
				sync.cond_wait(&p.wake, &p.mutex)
			}
		}
		outcome := post(p, w, &job)
		job_destroy(&job)
		sync.guard(&p.mutex)
		if i, found := slice.linear_search(p.sending[:], job.account); found {
			unordered_remove(&p.sending, i)
		}
		append(&p.results, Result{job.sub, outcome})
		// A job of the same account may have been waiting for this one.
		sync.cond_broadcast(&p.wake)
	}
}

// address_public reports whether an address that a push is about to connect to is on
// the public internet: not loopback, private, link-local, shared (CGNAT), multicast or
// reserved, nor an IPv6 address that embeds one of those. `sa` is a struct sockaddr_in or
// sockaddr_in6, whose address is at the same place on every system.
address_public :: proc(family: c.int, sa: []u8) -> bool {
	switch family {
	case curl.AF_INET:
		return len(sa) >= 8 && ipv4_public(sa[4:8])
	case curl.AF_INET6:
		return len(sa) >= 24 && ipv6_public(sa[8:24])
	}
	return false
}

@(private = "file")
ipv4_public :: proc(a: []u8) -> bool {
	switch {
	case a[0] == 0, a[0] == 10, a[0] == 127, a[0] >= 224:
		return false
	case a[0] == 100 && a[1] & 0xc0 == 64, // 100.64.0.0/10
	     a[0] == 169 && a[1] == 254,
	     a[0] == 172 && a[1] & 0xf0 == 16, // 172.16.0.0/12
	     a[0] == 192 && a[1] == 168,
	     a[0] == 192 && a[1] == 0 && a[2] == 0,
	     a[0] == 198 && a[1] & 0xfe == 18:
		// 198.18.0.0/15
		return false
	}
	return true
}

@(private = "file")
ipv6_public :: proc(a: []u8) -> bool {
	mapped := [12]u8 {
		10 = 0xff,
		11 = 0xff,
	} // ::ffff:0:0/96
	nat64 := [12]u8 {
		1 = 0x64,
		2 = 0xff,
		3 = 0x9b,
	} // 64:ff9b::/96
	prefix := a[:12]
	switch {
	case slice.equal(prefix, mapped[:]), slice.equal(prefix, nat64[:]):
		return ipv4_public(a[12:16])
	case a[0] == 0x20 && a[1] == 0x02:
		// 6to4
		return ipv4_public(a[2:6])
	case a[0] == 0, // ::/8: unspecified, loopback, IPv4-compatible
	     a[0] & 0xfe == 0xfc, // unique local
	     a[0] == 0xfe && a[1] >= 0x80, // link-local and site-local
	     a[0] == 0xff, // multicast
	     a[0] == 0x20 && a[1] == 0x01 && a[2] == 0x0d && a[3] == 0xb8:
		// documentation
		return false
	}
	return true
}

// Socket is CURLOPT_OPENSOCKETDATA for open_socket.
@(private = "file")
Socket :: struct {
	refused: bool, // an address wasn't public
}

// open_socket is the CURLOPT_OPENSOCKETFUNCTION for pushes. curl calls it with each
// address it's about to connect to, once the name is resolved, so a name that resolves to
// an address that isn't public is caught too.
@(private = "file")
open_socket :: proc "c" (user: rawptr, purpose: c.int, a: ^curl.Sockaddr) -> curl.Socket {
	context = runtime.default_context()
	sa := ([^]u8)(&a.addr)[:a.addrlen]
	if !address_public(a.family, sa) {
		(^Socket)(user).refused = true
		return curl.SOCKET_BAD
	}
	return curl.socket(a.family, a.socktype, a.protocol)
}

// post encrypts a job and POSTs it to its endpoint (RFC 8030 section 5), which
// answers 201 once it has accepted it.
@(private = "file")
post :: proc(p: ^Pusher, w: ^Worker, job: ^Job) -> Outcome {
	origin := origin(job.endpoint)
	body, ok := encrypt(job.payload, job.p256dh[:], job.auth[:], context.temp_allocator)
	if !ok {
		// A p256dh that isn't a valid point will never become valid, so drop the subscription.
		log.warnf("push: a subscription at %s has an invalid p256dh key", origin)
		return .Gone
	}
	jwt := vapid_token(p, w, origin)
	if jwt == "" {
		log.error("push: could not sign a VAPID token")
		return .Failed
	}

	lib := &p.lib
	h := w.handle
	if h == nil {
		return .Failed
	}
	lib.easy_reset(h)
	tc :: proc(s: string) -> cstring {
		return strings.clone_to_cstring(s, context.temp_allocator)
	}
	headers: curl.Slist
	defer if headers != nil {
		lib.slist_free_all(headers)
	}
	header :: proc(lib: ^curl.Lib, list: ^curl.Slist, format: string, args: ..any) {
		list^ = lib.slist_append(list^, tc(fmt.tprintf(format, ..args)))
	}
	header(lib, &headers, "Content-Type: application/octet-stream")
	header(lib, &headers, "Content-Encoding: aes128gcm")
	header(lib, &headers, "TTL: %d", job.ttl)
	header(lib, &headers, "Urgency: %s", URGENCY_NAMES[job.urgency])
	if job.topic != "" {
		header(lib, &headers, "Topic: %s", job.topic)
	}
	header(
		lib,
		&headers,
		"Authorization: vapid t=%s, k=%s",
		jwt,
		base64url(p.public[:], context.temp_allocator),
	)

	errors: [curl.ERROR_SIZE]u8
	answer := make([dynamic]u8, context.temp_allocator)
	sink := Sink{context, &answer}
	lib.easy_setopt(h, .Url, tc(job.endpoint))
	lib.easy_setopt(h, .Http_Header, headers)
	lib.easy_setopt(h, .Post_Field_Size, c.long(len(body)))
	lib.easy_setopt(h, .Post_Fields, raw_data(body))
	lib.easy_setopt(h, .Connect_Timeout, c.long(PUSH_CONNECT_TIMEOUT))
	lib.easy_setopt(h, .Timeout, c.long(PUSH_TIMEOUT))
	lib.easy_setopt(h, .No_Signal, c.long(1))
	lib.easy_setopt(h, .Error_Buffer, raw_data(errors[:]))
	lib.easy_setopt(h, .Write_Function, answer)
	lib.easy_setopt(h, .Write_Data, &sink)
	socket: Socket
	lib.easy_setopt(h, .Open_Socket_Function, open_socket)
	lib.easy_setopt(h, .Open_Socket_Data, &socket)
	code := lib.easy_perform(h)
	if socket.refused && code != 0 {
		log.infof("push: %s isn't on the public internet, so its subscription is dropped", origin)
		return .Gone
	}
	if code != 0 {
		why :=
			string(cstring(raw_data(errors[:]))) if errors[0] != 0 else string(lib.easy_strerror(code))
		report(p, origin, fmt.tprintf("could not reach the push service: %s", why))
		return .Failed
	}
	status: c.long
	lib.easy_getinfo(h, curl.INFO_RESPONSE_CODE, &status)
	switch status {
	case 200 ..= 299:
		report(p, origin, "")
		log.debugf("push: %s accepted a push (%d)", origin, status)
		return .Sent
	case 404, 410:
		log.debugf("push: %s reports that a subscription no longer exists (%d)", origin, status)
		return .Gone
	case:
		report(
			p,
			origin,
			fmt.tprintf("the push service answered %d: %s", status, string(answer[:])),
		)
		return .Failed
	}
}

// report logs that pushing to `origin` failed (with `err`), or that it works again
// (`err` is ""). Each change is only logged once.
@(private = "file")
report :: proc(p: ^Pusher, origin, err: string) {
	sync.guard(&p.mutex)
	if err == "" {
		if origin in p.failing {
			log.infof("push: pushing to %s works again", origin)
			key, _ := delete_key(&p.failing, origin)
			delete(key)
		}
		return
	}
	if origin not_in p.failing {
		p.failing[strings.clone(origin)] = true
		log.warnf("push: %s: %s", origin, err)
	}
}

// vapid_token returns the VAPID token for an origin, creating a new one when the cached
// token is about to expire.
@(private = "file")
vapid_token :: proc(p: ^Pusher, w: ^Worker, origin: string) -> string {
	now := time.now()
	if token, ok := w.tokens[origin]; ok && time.diff(now, token.expires) > VAPID_RENEW {
		return token.jwt
	}
	expires := time.time_add(now, VAPID_LIFETIME)
	jwt := vapid_jwt(&p.key, origin, p.subject, time.to_unix_seconds(expires))
	if jwt == "" {
		return ""
	}
	if origin in w.tokens {
		key, old := delete_key(&w.tokens, origin)
		delete(key)
		delete(old.jwt)
	}
	w.tokens[strings.clone(origin)] = {jwt, expires}
	return jwt
}

@(private = "file")
Sink :: struct {
	ctx:  runtime.Context,
	data: ^[dynamic]u8,
}

@(private = "file")
answer :: proc "c" (data: [^]u8, size, count: uint, user: rawptr) -> uint {
	sink := (^Sink)(user)
	context = sink.ctx
	n := int(size * count)
	room := PUSH_ANSWER_MOST - len(sink.data)
	if room > 0 {
		append(sink.data, ..data[:min(n, room)])
	}
	return uint(n)
}
