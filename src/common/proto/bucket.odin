package proto

import "core:time"

// Bucket is a token bucket, which paces or limits something: tokens (bytes,
// or requests) come in at a rate per second, up to a burst, and whatever goes
// out takes some. Pacing sends while there are tokens left, which may take
// them below zero; limiting only lets something through if there are enough
// for it (bucket_take).
//
// A bucket that was never refilled (`last` zero) fills up completely on its
// first refill.
Bucket :: struct {
	tokens: f64,
	last:   time.Tick, // when it was last refilled
}

// bucket_refill adds the tokens that `rate` gives since the last refill,
// keeping at most `burst`.
bucket_refill :: proc(b: ^Bucket, now: time.Tick, rate, burst: f64) {
	elapsed := time.duration_seconds(time.tick_diff(b.last, now))
	b.last = now
	b.tokens = min(b.tokens + elapsed * rate, burst)
}

// bucket_take takes `n` tokens if there are that many, and says whether it did.
bucket_take :: proc(b: ^Bucket, n: f64) -> bool {
	if b.tokens < n {
		return false
	}
	b.tokens -= n
	return true
}

// Keyed_Buckets is a bucket for each key (an address, a token, ...), all
// with the same rate and burst. Keys whose bucket has filled up again are
// forgotten now and then (a full bucket is as good as none), so it only holds
// the keys that were busy recently.
Keyed_Buckets :: struct($K: typeid) {
	by_key: map[K]Bucket,
}

// How many keys are kept before the full buckets are forgotten.
KEYED_BUCKETS_PRUNE :: 1024

keyed_buckets_destroy :: proc(kb: ^Keyed_Buckets($K)) {
	delete(kb.by_key)
	kb.by_key = nil
}

// keyed_bucket returns `key`'s bucket, refilled up to `now`. A key it has no
// bucket for gets a full one. The pointer is good until the next call.
keyed_bucket :: proc(kb: ^Keyed_Buckets($K), key: K, now: time.Tick, rate, burst: f64) -> ^Bucket {
	if key not_in kb.by_key {
		if len(kb.by_key) >= KEYED_BUCKETS_PRUNE {
			full := make([dynamic]K, context.temp_allocator)
			for k, b in kb.by_key {
				b := b
				bucket_refill(&b, now, rate, burst)
				if b.tokens >= burst {
					append(&full, k)
				}
			}
			for k in full {
				delete_key(&kb.by_key, k)
			}
		}
		kb.by_key[key] = {burst, now}
	}
	b := &kb.by_key[key]
	bucket_refill(b, now, rate, burst)
	return b
}

// keyed_peek returns what `key`'s bucket would hold at `now`, without
// keeping a bucket for it.
keyed_peek :: proc(kb: ^Keyed_Buckets($K), key: K, now: time.Tick, rate, burst: f64) -> f64 {
	b, found := kb.by_key[key]
	if !found {
		return burst
	}
	bucket_refill(&b, now, rate, burst)
	return b.tokens
}
