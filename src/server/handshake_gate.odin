package server

import "core:crypto"
import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/endian"
import "core:log"
import "core:net"
import "core:time"

import "common:proto"

// A handshake in progress ("half open": the server has answered the Init
// but not had the Finish yet) costs the server a session's memory until it
// finishes or times out, and the Init that started it may have come from a
// forged address. So that a flood of such Inits can't take every session
// and keep everyone out, both the main port and the media port admit
// handshakes through a Handshake_Gate:
//
//   - Over gate_cookie_after(max_sessions) half-open handshakes, an Init only
//     gets a Resp if it carries a cookie for its source address (see
//     proto/wire.odin). Others are answered with a cookie instead. That
//     costs no state, and forged addresses never see their cookie.
//   - At most half of the sessions may be half open. The rest is kept for
//     handshakes that have finished, which includes every rekey of the
//     connections that are already there.
//   - At most HALF_OPEN_PER_ADDRESS handshakes may be in progress from one
//     address, unless it's this machine (the web relay's browsers all come
//     from there).
//   - An address that has got the server password wrong too often has its
//     Inits ignored for a while (gate_wrong_password): PASSWORD_FAILURES at
//     once, then one every PASSWORD_FAILURE_EVERY. This machine is no
//     exception here, so guessing through the web relay is slowed down too,
//     at the price of the relay's browsers waiting together while somebody
//     guesses.
//
// The cookie is an HMAC of the address and port, under a secret that is
// replaced every COOKIE_ROTATE. The secret before it is still accepted, so a
// cookie lives between one and two of those.
Handshake_Gate :: struct {
	secrets:        [2][32]byte, // current and previous
	rotated:        time.Tick,
	// How many handshakes are in progress, in total and per address.
	half_open:      int,
	by_addr:        map[Gate_Addr]int,
	// Wrong server passwords by address.
	password_fails: Addr_Buckets,
	// When it last logged that it turned an Init away, so that a flood
	// doesn't flood the log too.
	warned:         time.Tick,
}

COOKIE_ROTATE :: 2 * time.Minute
HALF_OPEN_PER_ADDRESS :: 8
PASSWORD_FAILURES :: 10
PASSWORD_FAILURE_EVERY :: 30 * time.Second

// How often the gate logs that it turns Inits away, at most.
@(private = "file")
GATE_WARN_EVERY :: 10 * time.Second

// Gate_Addr is an address (without the port) as bytes, to count by.
Gate_Addr :: [17]byte

Gate_Verdict :: enum {
	Accept, // start the handshake (and call gate_opened)
	Cookie, // answer with the cookie that gate_check returned
	Drop,
}

gate_destroy :: proc(g: ^Handshake_Gate) {
	delete(g.by_addr)
	g.by_addr = nil
	addr_buckets_destroy(&g.password_fails)
}

// gate_wrong_password counts a handshake from `from` that had the wrong
// server password.
gate_wrong_password :: proc(g: ^Handshake_Gate, from: net.Endpoint) {
	g.password_fails.burst = PASSWORD_FAILURES
	g.password_fails.every = PASSWORD_FAILURE_EVERY
	addr_spend(&g.password_fails, from)
}

// gate_cookie_after returns how many half-open handshakes there may be
// before a cookie is asked for.
gate_cookie_after :: proc(max_sessions: int) -> int {
	return max(max_sessions / 16, 4)
}

// gate_check decides what to do with an Init from `from`, when the server
// has `sessions` sessions of `max_sessions`.
gate_check :: proc(
	g: ^Handshake_Gate,
	packet: []byte,
	from: net.Endpoint,
	sessions, max_sessions: int,
) -> (
	verdict: Gate_Verdict,
	cookie: [proto.COOKIE_SIZE]byte,
) {
	// Only an address that receives our answers can have had a password
	// refused, so this can't be used to shut out somebody else's address.
	if !addr_allowed(&g.password_fails, from) {
		gate_warn(g, "an address got the server password wrong too often")
		return .Drop, {}
	}
	if g.half_open >= gate_cookie_after(max_sessions) && !gate_cookie_valid(g, packet, from) {
		return .Cookie, gate_cookie(g, from, 0)
	}
	addr := gate_addr(from)
	switch {
	case sessions >= max_sessions:
		gate_warn(g, "the session table is full")
	case g.half_open >= max_sessions / 2:
		gate_warn(g, "too many handshakes are in progress")
	case !gate_local(from) && g.by_addr[addr] >= HALF_OPEN_PER_ADDRESS:
		gate_warn(g, "too many handshakes are in progress from one address")
	case:
		return .Accept, {}
	}
	return .Drop, {}
}

// gate_opened counts a handshake that gate_check accepted.
gate_opened :: proc(g: ^Handshake_Gate, from: net.Endpoint) {
	g.half_open += 1
	g.by_addr[gate_addr(from)] += 1
}

// gate_closed counts a handshake that was opened from `from` as no longer in
// progress, because it finished or was dropped.
gate_closed :: proc(g: ^Handshake_Gate, from: net.Endpoint) {
	g.half_open = max(g.half_open - 1, 0)
	addr := gate_addr(from)
	if n := g.by_addr[addr]; n > 1 {
		g.by_addr[addr] = n - 1
	} else {
		delete_key(&g.by_addr, addr)
	}
}

// gate_cookie returns the cookie for `from` under secret `which` (0 for the
// current one), replacing the secrets first if it's time.
@(private = "file")
gate_cookie :: proc(
	g: ^Handshake_Gate,
	from: net.Endpoint,
	which: int,
) -> (
	cookie: [proto.COOKIE_SIZE]byte,
) {
	if g.rotated == {} || time.tick_since(g.rotated) >= COOKIE_ROTATE {
		g.secrets[1] = g.secrets[0]
		crypto.rand_bytes(g.secrets[0][:])
		if g.rotated == {} {
			crypto.rand_bytes(g.secrets[1][:])
		}
		g.rotated = time.tick_now()
	}
	msg: [len(Gate_Addr) + 2]byte
	addr := gate_addr(from)
	copy(msg[:], addr[:])
	endian.unchecked_put_u16le(msg[len(addr):], u16(from.port))
	tag: [32]byte
	hmac.sum(hash.Algorithm.SHA256, tag[:], msg[:], g.secrets[which][:])
	copy(cookie[:], tag[:])
	return
}

@(private = "file")
gate_cookie_valid :: proc(g: ^Handshake_Gate, packet: []byte, from: net.Endpoint) -> bool {
	got := proto.init_cookie(packet) or_return
	for which in 0 ..< len(g.secrets) {
		want := gate_cookie(g, from, which)
		if crypto.compare_constant_time(want[:], got) == 1 {
			return true
		}
	}
	return false
}

// gate_addr returns the address of an endpoint, without the port, as bytes.
gate_addr :: proc(from: net.Endpoint) -> (addr: Gate_Addr) {
	switch a in from.address {
	case net.IP4_Address:
		addr[0] = 4
		b := a
		copy(addr[1:], b[:])
	case net.IP6_Address:
		addr[0] = 6
		b := transmute([16]u8)a
		copy(addr[1:17], b[:])
	}
	return
}

@(private = "file")
gate_local :: proc(from: net.Endpoint) -> bool {
	switch a in from.address {
	case net.IP4_Address:
		return a[0] == 127
	case net.IP6_Address:
		return a == net.IP6_Loopback
	}
	return false
}

@(private = "file")
gate_warn :: proc(g: ^Handshake_Gate, why: string) {
	if g.warned != {} && time.tick_since(g.warned) < GATE_WARN_EVERY {
		return
	}
	g.warned = time.tick_now()
	log.warnf("turning handshakes away: %s", why)
}
