package gateway

import "core:crypto/ecdh"
import "core:math"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"

import "common:http"
import "common:proto"

// Limits (docs/bot-api, "Limits" and "Security") keep a looping bot, or
// someone who isn't a bot, from taking down the gateway or the server:
//
// - Requests per token: each token has a bucket of Config.burst requests that
//   refills at Config.rate per second. Every request with a token takes one
//   from the bucket, including event sockets and transfers. With an empty
//   bucket the gateway answers 429 with Retry-After. A rate of 0 means no
//   limit.
// - Connections: at most Config.max_connections tokens can be in use at once
//   (503 beyond that), each token can have one event socket (events.odin),
//   and bodies are limited to MAX_BODY, except for uploads, which are
//   streamed (serve.odin, files.odin).
// - Silent sockets: HTTP_IDLE applies between requests (and between the
//   bytes of a body), EVENTS_IDLE applies to an event socket, where a live
//   client answers the gateway's pings.
// - /login carries a password, so it is only allowed over loopback or, behind
//   a reverse proxy (Config.behind_proxy), only for requests the proxy says
//   came over HTTPS (X-Forwarded-Proto). A token is as good as a password,
//   but a careless setup can't be prevented for tokens, whereas a password at
//   least has a safe way to be sent.

DEFAULT_RATE :: 10
DEFAULT_BURST :: 30
HTTP_IDLE :: 60 * time.Second
EVENTS_IDLE :: 2 * PING_EVERY + 15 * time.Second
// Buckets that haven't been used for this long are full again. They are
// forgotten once there are many of them.
BUCKET_FORGET :: 10 * time.Minute
BUCKETS_PRUNE_AT :: 1024

@(private)
Bucket :: struct {
	tokens: f64,
	last:   time.Tick,
}

// rate_take takes one request from the bucket of the token that `key`
// belongs to. If the bucket is empty, it returns a 429 reply that says when
// to retry.
@(private)
rate_take :: proc(g: ^Gateway, key: ^ecdh.Private_Key) -> (r: Reply, limited: bool) {
	if g.cfg.rate <= 0 {
		return
	}
	pub: [proto.KEY_SIZE]u8
	ecdh.private_key_public_bytes(key, pub[:])
	now := time.tick_now()
	burst := max(g.cfg.burst, 1)
	sync.guard(&g.limits_mutex)
	b, seen := g.buckets[pub]
	if !seen {
		if len(g.buckets) >= BUCKETS_PRUNE_AT {
			buckets_prune(g, now)
		}
		b = {
			tokens = burst,
			last   = now,
		}
	}
	b.tokens = min(
		b.tokens + time.duration_seconds(time.tick_diff(b.last, now)) * g.cfg.rate,
		burst,
	)
	b.last = now
	defer g.buckets[pub] = b
	if b.tokens < 1 {
		r = error_reply(
			429,
			"rate_limited",
			"Too many requests were made with this token. Please slow down.",
		)
		r.retry_after = max(1, int(math.ceil((1 - b.tokens) / g.cfg.rate)))
		return r, true
	}
	b.tokens -= 1
	return
}

@(private)
buckets_prune :: proc(g: ^Gateway, now: time.Tick) {
	stale := make([dynamic][proto.KEY_SIZE]u8, context.temp_allocator)
	for key, b in g.buckets {
		if time.tick_diff(b.last, now) > BUCKET_FORGET {
			append(&stale, key)
		}
	}
	for key in stale {
		delete_key(&g.buckets, key)
	}
}

// login_allowed says whether a /login may carry a password here. That is the
// case over loopback or, behind a proxy, only if the proxy says the bot
// connected over HTTPS (the proxy's own address says nothing in that case).
login_allowed :: proc(behind_proxy: bool, remote: net.Endpoint, forwarded_proto: string) -> bool {
	if behind_proxy {
		return strings.equal_fold(strings.trim_space(forwarded_proto), "https")
	}
	switch a in remote.address {
	case net.IP4_Address:
		return a[0] == 127
	case net.IP6_Address:
		return a == net.IP6_Loopback
	}
	return false
}

// idle_timeout makes a socket give up on a peer that has been silent for `d`,
// for both receiving and sending.
@(private)
idle_timeout :: proc(c: ^http.Conn, d: time.Duration) {
	net.set_option(c.sock, .Receive_Timeout, d)
	net.set_option(c.sock, .Send_Timeout, d)
}
