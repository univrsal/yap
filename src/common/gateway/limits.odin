package gateway

import "core:crypto/ecdh"
import "core:math"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"

import "common:http"
import "common:proto"

/*
Limits (docs/bot-api, "Limits" and "Security"), so that a loop in a bot,
or someone who isn't one, can't take the gateway or the server down:

- Requests per token: a bucket of Config.burst that fills at
  Config.rate a second, one taken by every request with a token (event
  sockets and transfers too); an empty one is 429 with Retry-After.
  0 for no limit.
- Connections: Config.max_connections tokens in use at once (503 past
  that), one event socket per token (events.odin), MAX_BODY a body
  but for uploads, which stream (serve.odin, files.odin).
- Sockets that say nothing: HTTP_IDLE between requests (and between a
  body's bytes), EVENTS_IDLE on an event socket, which a live client
  answers the gateway's pings on.
- /login, which carries a password, only over loopback, or, behind a
  reverse proxy (Config.behind_proxy), only what it says came over
  HTTPS (X-Forwarded-Proto). A token is as good as a password, but there
  is no stopping a careless setup for those; a password at least has a
  safe way.
*/

DEFAULT_RATE :: 10
DEFAULT_BURST :: 30
HTTP_IDLE :: 60 * time.Second
EVENTS_IDLE :: 2 * PING_EVERY + 15 * time.Second
// Buckets not used for this long are full again, and forgotten once
// there are many.
BUCKET_FORGET :: 10 * time.Minute
BUCKETS_PRUNE_AT :: 1024

@(private)
Bucket :: struct {
	tokens: f64,
	last:   time.Tick,
}

/*
rate_take takes a turn from the bucket of the token `key` is, or says
when to come back (429).
*/
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
		r = error_reply(429, "rate_limited", "Too many requests with this token; slow down.")
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

/*
login_allowed says whether a /login may carry a password here: over
loopback; or behind a proxy, only if it says the bot came over HTTPS
(then the proxy's own address says nothing).
*/
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

// idle_timeout has a socket give up on a peer quiet for `d`, either way.
@(private)
idle_timeout :: proc(c: ^http.Conn, d: time.Duration) {
	net.set_option(c.sock, .Receive_Timeout, d)
	net.set_option(c.sock, .Send_Timeout, d)
}
