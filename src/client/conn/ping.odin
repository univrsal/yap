package conn

import "core:time"

import "common:proto"

// How good the connection to the server is, shown in the indicator next to the
// server's name. The client pings the server every PING_INTERVAL (see
// proto/ping.odin) and keeps the last PING_WINDOW pings. From those it derives
// the round trip times and the share of pings that never got an answer.
//
// A ping counts as lost once PING_TIMEOUT has passed without a pong. A pong
// that arrives later than that is too late to be useful for voice anyway.
// Pings younger than that are still outstanding and are not counted either way.
//
// The bars show the worse of latency and loss (see connection_quality). Loss
// only counts where pings go unanswered in a row: a ping lost here and there
// leaves the bars green. FAIR_RUN of them in a row turn the bars yellow, and
// they stay yellow until RECOVER_RUN pings in a row have been answered again
// (Connection_Stats.shaky). LOST_IN_A_ROW in a row (a few seconds of silence)
// turn them red, because that means the connection is going down. After that,
// client_step gives up on the connection and periodically tries to establish a
// new one (CONNECTION_LOST).

PING_INTERVAL :: 500 * time.Millisecond
PING_WINDOW :: 60 // 30 seconds' worth
PING_TIMEOUT :: 3 * time.Second

// The thresholds at which the bars change colour.
GOOD_RTT :: 150 * time.Millisecond
FAIR_RTT :: 400 * time.Millisecond
// This many unanswered pings in a row make the connection fair, until this
// many in a row have been answered again.
FAIR_RUN :: 3
RECOVER_RUN :: 3
// This many unanswered pings in a row mean a poor connection.
LOST_IN_A_ROW :: 6

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
	// Indexed by id modulo PING_WINDOW so that a pong can find its ping directly.
	records:   [PING_WINDOW]Ping_Record,
}

Connection_Quality :: enum {
	Unknown, // no answers yet: just connected, or the server does not support Ping
	Poor,
	Fair,
	Good,
}

// Connection_Stats summarizes the window for the UI.
Connection_Stats :: struct {
	quality:  Connection_Quality,
	sent:     int, // pings old enough to judge
	lost:     int,
	lost_run: int, // unanswered pings in a row, most recent first
	// FAIR_RUN pings in a row went unanswered, and fewer than RECOVER_RUN
	// in a row have been answered since.
	shaky:    bool,
	last_rtt: time.Duration,
	avg_rtt:  time.Duration,
	min_rtt:  time.Duration,
	max_rtt:  time.Duration,
	// Mean difference between consecutive round trips, like the jitter in
	// RFC 3550 but without smoothing over the window.
	jitter:   time.Duration,
}

// ping_step sends the next ping when it is due.
ping_step :: proc(c: ^Server_Conn) {
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
	// Publishing on every send also catches pings that have just
	// timed out.
	publish_connection(c)
	trouble_step(c, connection_stats(p, time.tick_now()))
}

handle_pong :: proc(c: ^Server_Conn, pt: []byte) {
	p := &c.ping
	id := proto.decode_ping(pt)
	r := &p.records[id % PING_WINDOW]
	if r.id != id || r.answered || p.count == 0 {
		return // not a ping we are waiting for, or a duplicate
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
	// Going back from the latest ping, until a run of answers long enough to
	// have recovered (or one of losses long enough to be shaky) is found.
	answered_run, lost_here := 0, 0
	settled := false

	// Newest first: the run of losses is counted back from the latest ping,
	// and the jitter compares each round trip with the one before it.
	for i in 0 ..< p.count {
		id := p.next_id - 1 - u32(i)
		r := &p.records[id % PING_WINDOW]
		if !r.answered && time.tick_diff(r.sent, now) < PING_TIMEOUT {
			continue // still outstanding
		}
		s.sent += 1
		if !settled {
			if r.answered {
				answered_run, lost_here = answered_run + 1, 0
				settled = answered_run >= RECOVER_RUN
			} else {
				answered_run, lost_here = 0, lost_here + 1
				if lost_here >= FAIR_RUN {
					s.shaky, settled = true, true
				}
			}
		}
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
		return // Unknown, nothing to go on
	}
	s.avg_rtt = rtt_sum / time.Duration(answered)
	if diffs > 0 {
		s.jitter = diff_sum / time.Duration(diffs)
	}
	s.quality = connection_quality(s)
	return
}

connection_quality :: proc(s: Connection_Stats) -> Connection_Quality {
	switch {
	case s.lost_run >= LOST_IN_A_ROW:
		return .Poor
	case s.avg_rtt < GOOD_RTT && !s.shaky:
		return .Good
	case s.avg_rtt < FAIR_RTT:
		return .Fair
	}
	return .Poor
}

// connection_loss is the share of judged pings that got no answer, as a
// percentage.
connection_loss :: proc(s: Connection_Stats) -> f32 {
	if s.sent == 0 {
		return 0
	}
	return f32(s.lost) * 100 / f32(s.sent)
}
