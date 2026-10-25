#+build !wasi
package proto

import "core:testing"
import "core:time"

@(test)
test_bucket :: proc(t: ^testing.T) {
	now := time.tick_now()
	// A bucket that was never refilled starts full.
	b: Bucket
	bucket_refill(&b, now, 10, 30)
	testing.expect_value(t, b.tokens, 30)
	testing.expect(t, bucket_take(&b, 25))
	testing.expect(t, !bucket_take(&b, 6))
	testing.expect_value(t, b.tokens, 5)

	// It fills at the rate, up to the burst.
	bucket_refill(&b, time.tick_add(now, time.Second), 10, 30)
	testing.expect_value(t, b.tokens, 15)
	bucket_refill(&b, time.tick_add(now, time.Minute), 10, 30)
	testing.expect_value(t, b.tokens, 30)

	// Pacing may go below zero, which takes longer to pay off.
	b.tokens = -10
	bucket_refill(&b, time.tick_add(now, time.Minute + time.Second), 10, 30)
	testing.expect_value(t, b.tokens, 0)
}

@(test)
test_keyed_buckets :: proc(t: ^testing.T) {
	kb: Keyed_Buckets(int)
	defer keyed_buckets_destroy(&kb)
	now := time.tick_now()

	testing.expect(t, bucket_take(keyed_bucket(&kb, 1, now, 1, 2), 2))
	testing.expect(t, !bucket_take(keyed_bucket(&kb, 1, now, 1, 2), 1))
	testing.expect_value(t, keyed_peek(&kb, 1, now, 1, 2), 0)
	// Another key has a bucket of its own; peeking doesn't make one.
	testing.expect_value(t, keyed_peek(&kb, 2, now, 1, 2), 2)
	testing.expect_value(t, len(kb.by_key), 1)

	// Once there are many keys, the full buckets are forgotten when another
	// key comes.
	for k in 10 ..< 10 + KEYED_BUCKETS_PRUNE - 1 {
		keyed_bucket(&kb, k, now, 1, 2)
	}
	later := time.tick_add(now, time.Second)
	keyed_bucket(&kb, 5000, later, 1, 2)
	testing.expect_value(t, len(kb.by_key), 2) // key 1 (not full yet) and 5000
	testing.expect_value(t, keyed_peek(&kb, 1, later, 1, 2), 1)
}
