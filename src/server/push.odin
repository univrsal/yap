package server

import "base:runtime"
import "core:c"
import "core:crypto/ecdsa"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "common:memtrack"

/*
Web Push (misc/mobile): telling browsers about what's new while nobody
has the client open, through the push service each browser uses
(Google's, Mozilla's, Apple's).

A browser that subscribes is given this server's VAPID public key
(Push.public) and gets back an endpoint URL at its push service, with
two keys for encrypting to it. To tell it something, the server
encrypts a small payload for it (push_crypto.odin) and POSTs that to
the endpoint with libcurl, signed with the VAPID key; the push service
hands it to the browser, which shows it from its service worker
(web/sw.js), whether or not the page is open.

The POSTs are made on a thread of their own, so a slow push service
never holds up the loop: push_send queues a job, and what came of it
comes back by push_poll (an endpoint that answers 404 or 410 is gone
for good, and its subscription is to be forgotten).

The key is the config's push.vapid_key, made on the first run like the
server's own: browsers subscribed with its public half, and changing it
leaves every subscription useless.
*/

// The most jobs waiting at once; past that, pushes are dropped.
@(private = "file")
PUSH_JOBS_MOST :: 1024
// How long a push may take, connecting and in all.
@(private = "file")
PUSH_CONNECT_TIMEOUT :: 10
@(private = "file")
PUSH_TIMEOUT :: 20
// How long a VAPID token is good for, and how long before that a new
// one is made. Push services take at most a day.
@(private = "file")
VAPID_LIFETIME :: 12 * time.Hour
@(private = "file")
VAPID_RENEW :: time.Hour
// How much of a push service's answer is kept, for the log.
@(private = "file")
PUSH_ANSWER_MOST :: 512

// The config's "push".
Push_Config :: struct {
	enabled:   bool,
	vapid_key: string,
	subject:   string,
}

// How soon a push service is to deliver (RFC 8030's Urgency).
Push_Urgency :: enum u8 {
	Very_Low,
	Low,
	Normal,
	High,
}

@(private = "file")
URGENCY_NAMES := [Push_Urgency]string {
	.Very_Low = "very-low",
	.Low      = "low",
	.Normal   = "normal",
	.High     = "high",
}

// Push_Job is one message for one subscription. Its strings and slices
// are owned by the job.
Push_Job :: struct {
	sub:       i64, // whose it is, for the result
	endpoint:  string,
	p256dh:    [P256_PUBLIC_SIZE]u8,
	auth:      [PUSH_AUTH_SIZE]u8,
	payload:   []u8,
	ttl:       int, // seconds the push service may keep it
	urgency:   Push_Urgency,
	// A push still waiting at the push service with the same topic is
	// replaced; "" for none. At most 32 base64url characters.
	topic:     string,
}

Push_Outcome :: enum u8 {
	Sent,
	Gone, // the subscription is no more (404, 410)
	Failed, // this time; it may work next time
}

Push_Result :: struct {
	sub:     i64,
	outcome: Push_Outcome,
}

Vapid_Token :: struct {
	jwt:     string,
	expires: time.Time,
}

Push :: struct {
	enabled:   bool, // configured, and libcurl is there
	key:       ecdsa.Private_Key,
	public:    [P256_PUBLIC_SIZE]u8,
	subject:   string,
	curl:      Curl,
	thread:    ^thread.Thread,
	mutex:     sync.Mutex,
	wake:      sync.Cond,
	stop:      bool,
	jobs:      [dynamic]Push_Job,
	results:   [dynamic]Push_Result,
	// The thread's: its handle, kept so connections are too; tokens by
	// the push service's origin; and the origins that failed last time,
	// so a failure is logged once rather than for every push.
	handle:    Curl_Handle,
	tokens:    map[string]Vapid_Token,
	failing:   map[string]bool,
}

/*
push_open starts pushing, if the config has it on and libcurl is to be
had; without, push_send does nothing and Server_Info gives no key, so
clients don't offer it.
*/
push_open :: proc(p: ^Push, config: Push_Config) {
	if !config.enabled {
		log.info("push is off")
		return
	}
	if !vapid_key_parse(config.vapid_key, &p.key) {
		log.error("push's vapid_key in the config is not a valid key, so push is off")
		return
	}
	if !curl_load(&p.curl, "push") {
		log.warn("push is off")
		ecdsa.private_key_clear(&p.key)
		return
	}
	ecdsa.private_key_public_bytes(&p.key, p.public[:])
	p.subject = strings.clone(config.subject)
	p.enabled = true
	p.thread = thread.create_and_start_with_poly_data(p, push_run, init_context = context)
	log.infof("push on, as %s", config.subject)
}

push_close :: proc(p: ^Push) {
	if p.thread != nil {
		sync.lock(&p.mutex)
		p.stop = true
		sync.cond_signal(&p.wake)
		sync.unlock(&p.mutex)
		thread.join(p.thread)
		thread.destroy(p.thread)
	}
	for &job in p.jobs {
		push_job_destroy(&job)
	}
	delete(p.jobs)
	delete(p.results)
	for origin, token in p.tokens {
		delete(origin)
		delete(token.jwt)
	}
	delete(p.tokens)
	for origin in p.failing {
		delete(origin)
	}
	delete(p.failing)
	delete(p.subject)
	ecdsa.private_key_clear(&p.key)
	p^ = {}
}

/*
push_send queues a message for a subscription; the job's strings and
payload are copied. False if push is off, the endpoint isn't one, or
too much is waiting already.
*/
push_send :: proc(p: ^Push, job: Push_Job) -> bool {
	if !p.enabled || push_origin(job.endpoint) == "" || len(job.payload) > PUSH_PAYLOAD_MOST {
		return false
	}
	job := job
	job.endpoint = strings.clone(job.endpoint)
	job.topic = strings.clone(job.topic)
	job.payload = clone_bytes(job.payload)
	sync.guard(&p.mutex)
	if len(p.jobs) >= PUSH_JOBS_MOST {
		push_job_destroy(&job)
		return false
	}
	append(&p.jobs, job)
	sync.cond_signal(&p.wake)
	return true
}

// push_poll takes what came of a push, if anything has.
@(require_results)
push_poll :: proc(p: ^Push) -> (r: Push_Result, ok: bool) {
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

// push_waiting is whether jobs are queued or results unread, for tests
// and the CLI to wait on.
push_waiting :: proc(p: ^Push) -> (jobs, results: int) {
	sync.guard(&p.mutex)
	return len(p.jobs), len(p.results)
}

/*
push_origin is an endpoint's origin, "https://host[:port]", which is
what its VAPID token is for; "" if it isn't an https:// URL with a path.
*/
push_origin :: proc(endpoint: string) -> string {
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
push_job_destroy :: proc(job: ^Push_Job) {
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

// push_run is the push thread: the jobs, as they come.
@(private = "file")
push_run :: proc(p: ^Push) {
	memtrack.thread_init()
	jobs := make([dynamic]Push_Job)
	defer delete(jobs)
	p.handle = p.curl.easy_init()
	defer if p.handle != nil {
		p.curl.easy_cleanup(p.handle)
	}
	for {
		free_all(context.temp_allocator)
		{
			sync.guard(&p.mutex)
			for !p.stop && len(p.jobs) == 0 {
				sync.cond_wait(&p.wake, &p.mutex)
			}
			if p.stop {
				return
			}
			append(&jobs, ..p.jobs[:])
			clear(&p.jobs)
		}
		for &job in jobs {
			outcome := push_post(p, &job)
			push_job_destroy(&job)
			sync.guard(&p.mutex)
			append(&p.results, Push_Result{job.sub, outcome})
		}
		clear(&jobs)
	}
}

/*
push_post encrypts a job and POSTs it to its endpoint (RFC 8030 section
5), which answers 201 when it has taken it.
*/
@(private = "file")
push_post :: proc(p: ^Push, job: ^Push_Job) -> Push_Outcome {
	origin := push_origin(job.endpoint)
	body, ok := push_encrypt(job.payload, job.p256dh[:], job.auth[:], context.temp_allocator)
	if !ok {
		// A p256dh that isn't a point is never going to be one.
		log.warnf("push: a subscription at %s has a key that isn't one", origin)
		return .Gone
	}
	jwt := vapid_token(p, origin)
	if jwt == "" {
		log.error("push: could not sign a VAPID token")
		return .Failed
	}

	lib := &p.curl
	h := p.handle
	if h == nil {
		return .Failed
	}
	lib.easy_reset(h)
	tc :: proc(s: string) -> cstring {
		return strings.clone_to_cstring(s, context.temp_allocator)
	}
	headers: Curl_Slist
	defer if headers != nil {
		lib.slist_free_all(headers)
	}
	header :: proc(lib: ^Curl, list: ^Curl_Slist, format: string, args: ..any) {
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

	errors: [CURL_ERROR_SIZE]u8
	answer := make([dynamic]u8, context.temp_allocator)
	sink := Push_Sink{context, &answer}
	lib.easy_setopt(h, .Url, tc(job.endpoint))
	lib.easy_setopt(h, .Http_Header, headers)
	lib.easy_setopt(h, .Post_Field_Size, c.long(len(body)))
	lib.easy_setopt(h, .Post_Fields, raw_data(body))
	lib.easy_setopt(h, .Connect_Timeout, c.long(PUSH_CONNECT_TIMEOUT))
	lib.easy_setopt(h, .Timeout, c.long(PUSH_TIMEOUT))
	lib.easy_setopt(h, .No_Signal, c.long(1))
	lib.easy_setopt(h, .Error_Buffer, raw_data(errors[:]))
	lib.easy_setopt(h, .Write_Function, push_answer)
	lib.easy_setopt(h, .Write_Data, &sink)
	if code := lib.easy_perform(h); code != 0 {
		why := string(cstring(raw_data(errors[:]))) if errors[0] != 0 else string(lib.easy_strerror(code))
		push_report(p, origin, fmt.tprintf("could not reach it: %s", why))
		return .Failed
	}
	status: c.long
	lib.easy_getinfo(h, CURLINFO_RESPONSE_CODE, &status)
	switch status {
	case 200 ..= 299:
		push_report(p, origin, "")
		log.debugf("push: %s took one (%d)", origin, status)
		return .Sent
	case 404, 410:
		log.debugf("push: %s says a subscription is gone (%d)", origin, status)
		return .Gone
	case:
		push_report(p, origin, fmt.tprintf("it answered %d: %s", status, string(answer[:])))
		return .Failed
	}
}

// push_report logs that pushing to `origin` failed (`err`), or works
// again ("" for err), once for each change.
@(private = "file")
push_report :: proc(p: ^Push, origin, err: string) {
	if err == "" {
		if origin in p.failing {
			log.infof("push: %s works again", origin)
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

// vapid_token is the token for an origin, made anew when it's near its
// end.
@(private = "file")
vapid_token :: proc(p: ^Push, origin: string) -> string {
	now := time.now()
	if token, ok := p.tokens[origin]; ok && time.diff(now, token.expires) > VAPID_RENEW {
		return token.jwt
	}
	expires := time.time_add(now, VAPID_LIFETIME)
	jwt := vapid_jwt(&p.key, origin, p.subject, time.to_unix_seconds(expires))
	if jwt == "" {
		return ""
	}
	if origin in p.tokens {
		key, old := delete_key(&p.tokens, origin)
		delete(key)
		delete(old.jwt)
	}
	p.tokens[strings.clone(origin)] = {jwt, expires}
	return jwt
}

@(private = "file")
Push_Sink :: struct {
	ctx:  runtime.Context,
	data: ^[dynamic]u8,
}

@(private = "file")
push_answer :: proc "c" (data: [^]u8, size, count: uint, user: rawptr) -> uint {
	sink := (^Push_Sink)(user)
	context = sink.ctx
	n := int(size * count)
	room := PUSH_ANSWER_MOST - len(sink.data)
	if room > 0 {
		append(sink.data, ..data[:min(n, room)])
	}
	return uint(n)
}

