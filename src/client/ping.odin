package client

import "core:time"

import "../proto"

/*
How good the connection to the server is, for the indicator next to the
server's name: the client pings the server every PING_INTERVAL (see
proto/ping.odin) and keeps the last PING_WINDOW of them. From those come
the round trip times and the share that never got an answer.

A ping counts as lost once it has gone PING_TIMEOUT without a pong; a
pong that turns up later than that is too late to be any use for voice
anyway. Pings younger than that are still out and aren't counted either
way.

The bars go by the worse of latency and loss (connection_quality).
Loss is judged over the whole window, so one lost ping doesn't turn the
bars yellow, but a few in a row do straight away: that's the connection
going, not noise.
*/

PING_INTERVAL :: 500 * time.Millisecond
PING_WINDOW :: 60 // 30 seconds' worth
PING_TIMEOUT :: 2 * time.Second

// Where the bars change colour.
GOOD_RTT :: 100 * time.Millisecond
FAIR_RTT :: 250 * time.Millisecond
GOOD_LOSS :: 2 // percent
FAIR_LOSS :: 10
// This many unanswered pings in a row is a poor connection, whatever
// the rest of the window says.
LOST_IN_A_ROW :: 3

Ping_Record :: struct {
	id:       u32,
	sent:     time.Tick,
	rtt:      time.Duration,
	answered: bool,
}

Ping_Tracker :: struct {
	next_id:   u32,
	last_sent: time.Tick,
	count:     int, // how many of `records` are in use
	// By id modulo PING_WINDOW, so a pong finds its ping directly.
	records:   [PING_WINDOW]Ping_Record,
}

Connection_Quality :: enum {
	Unknown, // no answers yet: just connected, or a server without Ping
	Poor,
	Fair,
	Good,
}

// Connection_Stats sums up the window, for the UI.
Connection_Stats :: struct {
	quality:  Connection_Quality,
	sent:     int, // pings old enough to judge
	lost:     int,
	lost_run: int, // unanswered pings in a row, most recent first
	last_rtt: time.Duration,
	avg_rtt:  time.Duration,
	min_rtt:  time.Duration,
	max_rtt:  time.Duration,
	// Mean difference between consecutive round trips, like RFC 3550's
	// jitter, but unsmoothed over the window.
	jitter:   time.Duration,
}

// ping_step sends the next ping when it's due.
ping_step :: proc(c: ^Voice_Client) {
	p := &c.ping
	if p.count > 0 && time.tick_since(p.last_sent) < PING_INTERVAL {
		return
	}
	id := p.next_id
	p.next_id += 1
	p.last_sent = time.tick_now()
	p.records[id % PING_WINDOW] = {
		id   = id,
		sent = p.last_sent,
	}
	p.count = min(p.count + 1, PING_WINDOW)

	buf: [proto.PING_SIZE]byte
	send_data(c, proto.encode_ping(&buf, .Ping, id))
	// Publishing on every send also catches pings that have just run
	// out of time.
	publish_connection(c)
}

handle_pong :: proc(c: ^Voice_Client, pt: []byte) {
	p := &c.ping
	id := proto.decode_ping(pt)
	r := &p.records[id % PING_WINDOW]
	if r.id != id || r.answered || p.count == 0 {
		return // not one we're waiting for, or a duplicate
	}
	rtt := time.tick_since(r.sent)
	if rtt > PING_TIMEOUT {
		return // already counted as lost
	}
	r.rtt, r.answered = rtt, true
	publish_connection(c)
}

connection_stats :: proc(p: ^Ping_Tracker, now: time.Tick) -> (s: Connection_Stats) {
	rtt_sum: time.Duration
	diff_sum: time.Duration
	diffs := 0
	answered := 0
	prev_rtt: time.Duration
	have_prev := false
	counting_run := true

	// Newest first: the run of losses counts back from the latest ping,
	// and the jitter compares each round trip with the one before.
	for i in 0 ..< p.count {
		id := p.next_id - 1 - u32(i)
		r := &p.records[id % PING_WINDOW]
		if !r.answered && time.tick_diff(r.sent, now) < PING_TIMEOUT {
			continue // still out
		}
		s.sent += 1
		if !r.answered {
			s.lost += 1
			if counting_run {
				s.lost_run += 1
			}
			continue
		}
		counting_run = false
		if answered == 0 {
			s.last_rtt, s.min_rtt, s.max_rtt = r.rtt, r.rtt, r.rtt
		}
		answered += 1
		rtt_sum += r.rtt
		s.min_rtt = min(s.min_rtt, r.rtt)
		s.max_rtt = max(s.max_rtt, r.rtt)
		if have_prev {
			diff_sum += abs(r.rtt - prev_rtt)
			diffs += 1
		}
		prev_rtt, have_prev = r.rtt, true
	}
	if answered == 0 {
		return // Unknown, with nothing to go on
	}
	s.avg_rtt = rtt_sum / time.Duration(answered)
	if diffs > 0 {
		s.jitter = diff_sum / time.Duration(diffs)
	}
	s.quality = connection_quality(s)
	return
}

connection_quality :: proc(s: Connection_Stats) -> Connection_Quality {
	loss := connection_loss(s)
	switch {
	case s.lost_run >= LOST_IN_A_ROW:
		return .Poor
	case s.avg_rtt < GOOD_RTT && loss <= GOOD_LOSS:
		return .Good
	case s.avg_rtt < FAIR_RTT && loss <= FAIR_LOSS:
		return .Fair
	}
	return .Poor
}

// connection_loss is the share of judged pings that got no answer, in
// percent.
connection_loss :: proc(s: Connection_Stats) -> f32 {
	if s.sent == 0 {
		return 0
	}
	return f32(s.lost) * 100 / f32(s.sent)
}
