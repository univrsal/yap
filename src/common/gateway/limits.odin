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
//   came over HTTPS (X-Forwarded-Proto), and that come from the proxy. A token is as good as a password,
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

// Each address may make the gateway open OPENS_PER_ADDRESS connections to the
// server at once, then one every OPEN_EVERY. A connection is opened for
// every /login and for a token the gateway hasn't seen yet (Job.remote, see
// new_conn), and each one is a handshake with the server, a password hash for
// /login, and one of max_connections until it fails. Without this, made-up
// tokens, which each have a bucket of their own, would get all of that for
// nothing.
OPENS_PER_ADDRESS :: 10
OPEN_EVERY :: 6 * time.Second

Address_Key :: [17]u8

// opens_take takes one of the connections `remote` may have opened. If there
// is none left, it returns a 429 reply. Only the gateway thread uses it.
@(private)
opens_take :: proc(g: ^Gateway, remote: net.Address) -> (r: Reply, limited: bool) {
	key: Address_Key
	switch a in remote {
	case net.IP4_Address:
		key[0] = 4
		b := a
		copy(key[1:], b[:])
	case net.IP6_Address:
		key[0] = 6
		b := transmute([16]u8)a
		copy(key[1:], b[:])
	case:
		return // in tests, Jobs made by hand have no address
	}
	now := time.tick_now()
	b, seen := g.opens[key]
	if !seen {
		if len(g.opens) >= BUCKETS_PRUNE_AT {
			stale := make([dynamic]Address_Key, context.temp_allocator)
			for k, old in g.opens {
				if time.tick_diff(old.last, now) > BUCKET_FORGET {
					append(&stale, k)
				}
			}
			for k in stale {
				delete_key(&g.opens, k)
			}
		}
		b = {
			tokens = OPENS_PER_ADDRESS,
			last   = now,
		}
	}
	b.tokens = min(
		b.tokens +
		time.duration_seconds(time.tick_diff(b.last, now)) / time.duration_seconds(OPEN_EVERY),
		OPENS_PER_ADDRESS,
	)
	b.last = now
	defer g.opens[key] = b
	if b.tokens < 1 {
		r = error_reply(
			429,
			"rate_limited",
			"Too many new connections were asked for from this address. Please slow down.",
		)
		r.retry_after = max(1, int(math.ceil((1 - b.tokens) * time.duration_seconds(OPEN_EVERY))))
		return r, true
	}
	b.tokens -= 1
	return
}

// client_address returns where a request came from: the address of the
// connection, or behind a trusted proxy (login_allowed), the address the
// proxy says it came from (the last one in X-Forwarded-For, which is the one
// the proxy added).
@(private)
client_address :: proc(g: ^Gateway, c: ^http.Conn, req: ^http.Request) -> net.Address {
	if !g.cfg.behind_proxy || !proxy_trusted(g.cfg.trusted_proxy, c.remote) {
		return c.remote.address
	}
	forwarded := http.header(req, "X-Forwarded-For")
	if i := strings.last_index_byte(forwarded, ','); i >= 0 {
		forwarded = forwarded[i + 1:]
	}
	if a := net.parse_address(strings.trim_space(forwarded)); a != nil {
		return a
	}
	return c.remote.address
}

// proxy_trusted says whether a request from `remote` comes from the reverse
// proxy: `trusted_proxy` if it is set, otherwise anything on this machine or
// in a private network.
proxy_trusted :: proc(trusted_proxy: net.Address, remote: net.Endpoint) -> bool {
	if trusted_proxy != nil {
		return remote.address == trusted_proxy
	}
	return address_private(remote.address)
}

// login_allowed says whether a /login may carry a password here. That is the
// case over loopback or, behind a proxy, only if the proxy says the bot
// connected over HTTPS (the proxy's own address says nothing in that case).
// Only the proxy is believed, though, since the port may be reachable
// without going through it: `trusted_proxy` if it is set, otherwise anything
// on this machine or in a private network.
login_allowed :: proc(
	behind_proxy: bool,
	trusted_proxy: net.Address,
	remote: net.Endpoint,
	forwarded_proto: string,
) -> bool {
	if behind_proxy {
		https := strings.equal_fold(strings.trim_space(forwarded_proto), "https")
		return https && proxy_trusted(trusted_proxy, remote)
	}
	return address_loopback(remote.address)
}

address_loopback :: proc(address: net.Address) -> bool {
	switch a in address {
	case net.IP4_Address:
		return a[0] == 127
	case net.IP6_Address:
		return a == net.IP6_Loopback
	}
	return false
}

// address_private says whether an address is this machine's or one of a
// private network (RFC 1918, or an IPv6 unique local address), where a
// reverse proxy in front of a container usually is.
address_private :: proc(address: net.Address) -> bool {
	if address_loopback(address) {
		return true
	}
	switch a in address {
	case net.IP4_Address:
		return a[0] == 10 || a[0] == 172 && a[1] & 0xf0 == 16 || a[0] == 192 && a[1] == 168
	case net.IP6_Address:
		return u16(a[0]) & 0xfe00 == 0xfc00
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
