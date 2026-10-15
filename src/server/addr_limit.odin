package server

import "core:net"
import "core:time"

// Addr_Buckets limits how often something may happen per address (without
// the port), with a token bucket for each address: `burst` at once, then
// one every `every`. Addresses whose bucket has filled up again are
// forgotten now and then, so the map only holds those that were busy
// recently.
Addr_Buckets :: struct {
	burst:   int,
	every:   time.Duration,
	by_addr: map[Gate_Addr]Addr_Bucket,
}

Addr_Bucket :: struct {
	tokens: f64,
	last:   time.Tick,
}

// How many addresses are kept before the full buckets are forgotten.
@(private = "file")
ADDR_BUCKETS_PRUNE :: 1024

addr_buckets_destroy :: proc(b: ^Addr_Buckets) {
	delete(b.by_addr)
	b.by_addr = nil
}

// addr_take takes a token for `from`, if there is one.
addr_take :: proc(b: ^Addr_Buckets, from: net.Endpoint) -> bool {
	bucket := addr_bucket(b, from)
	if bucket.tokens < 1 {
		return false
	}
	bucket.tokens -= 1
	return true
}

// addr_spend takes a token for `from` even if there is none left, which
// makes the address wait longer. It's for counting something that has
// already happened.
addr_spend :: proc(b: ^Addr_Buckets, from: net.Endpoint) {
	bucket := addr_bucket(b, from)
	bucket.tokens = max(bucket.tokens - 1, -f64(b.burst))
}

// addr_allowed says whether `from` has a token left, without taking it.
addr_allowed :: proc(b: ^Addr_Buckets, from: net.Endpoint) -> bool {
	addr := gate_addr(from)
	bucket, found := b.by_addr[addr]
	if !found {
		return true
	}
	return addr_refill(b, bucket, time.tick_now()).tokens >= 1
}

@(private = "file")
addr_bucket :: proc(b: ^Addr_Buckets, from: net.Endpoint) -> ^Addr_Bucket {
	now := time.tick_now()
	if len(b.by_addr) >= ADDR_BUCKETS_PRUNE {
		addr_prune(b, now)
	}
	addr := gate_addr(from)
	if addr not_in b.by_addr {
		b.by_addr[addr] = {
			tokens = f64(b.burst),
			last   = now,
		}
	}
	bucket := &b.by_addr[addr]
	bucket^ = addr_refill(b, bucket^, now)
	return bucket
}

@(private = "file")
addr_refill :: proc(b: ^Addr_Buckets, bucket: Addr_Bucket, now: time.Tick) -> Addr_Bucket {
	elapsed := time.tick_diff(bucket.last, now)
	return {
		tokens = min(
			f64(b.burst),
			bucket.tokens + time.duration_seconds(elapsed) / time.duration_seconds(b.every),
		),
		last = now,
	}
}

@(private = "file")
addr_prune :: proc(b: ^Addr_Buckets, now: time.Tick) {
	full := make([dynamic]Gate_Addr, context.temp_allocator)
	for addr, bucket in b.by_addr {
		if addr_refill(b, bucket, now).tokens >= f64(b.burst) {
			append(&full, addr)
		}
	}
	for addr in full {
		delete_key(&b.by_addr, addr)
	}
}
