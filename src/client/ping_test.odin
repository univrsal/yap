#+build !wasi
package client

import "core:testing"
import "core:time"

// Records pings sent a second apart, the last of them just old enough to
// judge at `now`; a negative rtt means that one got no answer.
@(private = "file")
fill :: proc(p: ^Ping_Tracker, now: time.Tick, rtts: []time.Duration) {
	for rtt, i in rtts {
		id := p.next_id
		p.next_id += 1
		sent := time.tick_add(now, -PING_TIMEOUT - time.Duration(len(rtts) - 1 - i) * time.Second)
		p.records[id % PING_WINDOW] = {
			id       = id,
			sent     = sent,
			rtt      = max(rtt, 0),
			answered = rtt >= 0,
		}
		p.count = min(p.count + 1, PING_WINDOW)
	}
}

@(private = "file")
MS :: time.Millisecond

@(test)
test_connection_unknown :: proc(t: ^testing.T) {
	p: Ping_Tracker
	now := time.tick_now()
	testing.expect_value(t, connection_stats(&p, now).quality, Connection_Quality.Unknown)

	// Only unanswered pings: a server that doesn't know Ping.
	fill(&p, now, {-1, -1, -1, -1})
	s := connection_stats(&p, now)
	testing.expect_value(t, s.quality, Connection_Quality.Unknown)
	testing.expect_value(t, s.lost, 4)
}

@(test)
test_connection_stats :: proc(t: ^testing.T) {
	p: Ping_Tracker
	now := time.tick_now()
	fill(&p, now, {20 * MS, 40 * MS, 20 * MS, 50 * MS})
	s := connection_stats(&p, now)
	testing.expect_value(t, s.quality, Connection_Quality.Good)
	testing.expect_value(t, s.sent, 4)
	testing.expect_value(t, s.lost, 0)
	testing.expect_value(t, s.last_rtt, 50 * MS)
	testing.expect_value(t, s.avg_rtt, 32500 * time.Microsecond)
	testing.expect_value(t, s.min_rtt, 20 * MS)
	testing.expect_value(t, s.max_rtt, 50 * MS)
	testing.expect_value(t, s.jitter, 70 * MS / 3) // (30 + 20 + 20) / 3
}

@(test)
test_connection_pending_not_counted :: proc(t: ^testing.T) {
	p: Ping_Tracker
	now := time.tick_now()
	fill(&p, now, {20 * MS, 20 * MS})
	// Just sent, no answer yet: neither lost nor answered.
	id := p.next_id
	p.next_id += 1
	p.records[id % PING_WINDOW] = {
		id   = id,
		sent = now,
	}
	p.count += 1
	s := connection_stats(&p, now)
	testing.expect_value(t, s.sent, 2)
	testing.expect_value(t, s.lost, 0)
}

@(test)
test_connection_quality :: proc(t: ^testing.T) {
	now := time.tick_now()
	good: [PING_WINDOW]time.Duration
	for &d in good {
		d = 30 * MS
	}

	{
		// One lost ping in a full window is still good.
		p: Ping_Tracker
		rtts := good
		rtts[10] = -1
		fill(&p, now, rtts[:])
		testing.expect_value(t, connection_stats(&p, now).quality, Connection_Quality.Good)
	}
	{
		// A few scattered losses make it fair.
		p: Ping_Tracker
		rtts := good
		rtts[10], rtts[20], rtts[30] = -1, -1, -1
		fill(&p, now, rtts[:])
		testing.expect_value(t, connection_stats(&p, now).quality, Connection_Quality.Fair)
	}
	{
		// So does a slow one.
		p: Ping_Tracker
		fill(&p, now, {150 * MS, 160 * MS})
		testing.expect_value(t, connection_stats(&p, now).quality, Connection_Quality.Fair)
	}
	{
		p: Ping_Tracker
		fill(&p, now, {300 * MS, 400 * MS})
		testing.expect_value(t, connection_stats(&p, now).quality, Connection_Quality.Poor)
	}
	{
		// The latest few lost in a row is poor straight away.
		p: Ping_Tracker
		rtts := good
		rtts[PING_WINDOW - 1], rtts[PING_WINDOW - 2], rtts[PING_WINDOW - 3] = -1, -1, -1
		fill(&p, now, rtts[:])
		s := connection_stats(&p, now)
		testing.expect_value(t, s.lost_run, 3)
		testing.expect_value(t, s.quality, Connection_Quality.Poor)
	}
}
