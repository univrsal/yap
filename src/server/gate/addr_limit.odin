package gate

import "core:net"
import "core:time"

import "common:proto"

// Addr_Buckets limits how often something may happen per address (without
// the port), with a token bucket for each address (proto.Keyed_Buckets):
// `burst` at once, then one every `every`.
Addr_Buckets :: struct {
	burst:   int,
	every:   time.Duration,
	buckets: proto.Keyed_Buckets(Key),
}

addr_buckets_destroy :: proc(b: ^Addr_Buckets) {
	proto.keyed_buckets_destroy(&b.buckets)
}

// addr_take takes a token for `from`, if there is one.
addr_take :: proc(b: ^Addr_Buckets, from: net.Endpoint) -> bool {
	return proto.bucket_take(addr_bucket(b, from), 1)
}

// addr_spend takes a token for `from` even if there is none left, which
// makes the address wait longer. It's for counting something that has
// already happened.
addr_spend :: proc(b: ^Addr_Buckets, from: net.Endpoint) {
	bucket := addr_bucket(b, from)
	bucket.tokens = max(bucket.tokens - 1, -f64(b.burst))
}

// addr_allowed says whether `from` has a token left, without taking it. An
// address without a bucket has, even before `burst` and `every` are set
// (gate.odin sets them on the first failure).
addr_allowed :: proc(b: ^Addr_Buckets, from: net.Endpoint) -> bool {
	addr := key_of(from)
	if addr not_in b.buckets.by_key {
		return true
	}
	return proto.keyed_peek(&b.buckets, addr, time.tick_now(), addr_rate(b), f64(b.burst)) >= 1
}

@(private = "file")
addr_bucket :: proc(b: ^Addr_Buckets, from: net.Endpoint) -> ^proto.Bucket {
	return proto.keyed_bucket(
		&b.buckets,
		key_of(from),
		time.tick_now(),
		addr_rate(b),
		f64(b.burst),
	)
}

@(private = "file")
addr_rate :: proc(b: ^Addr_Buckets) -> f64 {
	return 1 / time.duration_seconds(b.every)
}
