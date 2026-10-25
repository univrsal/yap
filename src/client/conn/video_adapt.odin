package conn

import log "common:wlog"
import "core:time"

import "client:video"
import "common:proto"

// Adapting a share's bitrate to what the viewers report.

// Adapting the bitrate (adapt_bitrate): the thresholds that say the network
// cannot keep up (in thousandths of fragments missing, and ms of queueing), the
// thresholds that say it can, how often to cut, how long it has to be good
// before going up, and how far down it may go (a fraction of the configured
// bitrate).
ADAPT_LOSS_BAD :: 20
ADAPT_DELAY_BAD :: 150
ADAPT_LOSS_GOOD :: 5
ADAPT_DELAY_GOOD :: 40
ADAPT_CUT_EVERY :: 2 * time.Second
ADAPT_GOOD_FOR :: 4 * time.Second
ADAPT_FLOOR :: 8
// With no reports for this long, nobody is watching: go back to the configured bitrate.
ADAPT_QUIET :: 10 * time.Second
// How long after the encoder has changed its bitrate reports are not acted on:
// it starts again with a keyframe, which goes out as a burst, and the reports
// that come in meanwhile still cover the time before.
ADAPT_SETTLE :: 2 * time.Second
// The library takes up a new bitrate only if it differs by at least this part
// of the current one (yv_share_set_bitrate); a smaller change counts as done.
ADAPT_MIN_CHANGE :: 5
// How long the minimum delay is measured over (twice this).
DELAY_WINDOW :: 5 * time.Second

// send_report tells the server how well a stream we watch has reached us
// during the past second: `asked` fragments were asked for again, and
// `kbit_in` came in.
send_report :: proc(c: ^Server_Conn, in_: ^Video_In, asked, kbit_in: int) {
	r := proto.Video_Report {
		loss = asked * 1000 / max(in_.stats_frags, 1),
		kbit = kbit_in,
	}
	if in_.delay_n > 0 {
		r.delay_ms = int(in_.delay_sum / i64(in_.delay_n))
	}
	buf: [proto.REPORT_CAMERA_SIZE]u8
	link_send(&c.media.link, proto.encode_report_up(&buf, in_.key.user, r, in_.key.stream))
}

// note_delay records when a frame's first fragment arrived, relative to the
// sharer's clock (its `ts`). The clocks differ by an unknown amount, so only
// the comparison with the minimum of the last 10 seconds is meaningful: it
// shows a queue building up on the way.
note_delay :: proc(in_: ^Video_In, ts: u32, now: time.Tick) {
	ms := u32(now._nsec / i64(time.Millisecond))
	rel := i64(i32(ms - ts))
	if in_.delay_min_at == {} || time.tick_diff(in_.delay_min_at, now) >= DELAY_WINDOW {
		in_.delay_min[1] = in_.delay_min[0] if in_.delay_min_at != {} else rel
		in_.delay_min[0] = rel
		in_.delay_min_at = now
	}
	in_.delay_min[0] = min(in_.delay_min[0], rel)
	least := min(in_.delay_min[0], in_.delay_min[1])
	in_.delay_sum += rel - least
	in_.delay_n += 1
}

// video_reports is called when the server says how one of our streams reaches
// its viewers.
video_reports :: proc(c: ^Server_Conn, stream: proto.Video_Stream, s: proto.Video_Reports) {
	o := &c.video.outs[stream]
	if !o.live {
		return
	}
	o.reports = s
	o.reports_at = time.tick_now()
	adapt_bitrate(o, s.worst, video.share_max_kbit(stream), o.reports_at)
}

// note_encoding keeps track of the bitrate the encoder runs at, and of when it
// last changed (adapt_bitrate).
note_encoding :: proc(o: ^Video_Out, kbit: int, now: time.Tick) {
	if kbit != o.encoding_kbit {
		o.encoding_kbit = kbit
		o.encoding_at = now
	}
}

// adapt_bitrate moves a stream's bitrate according to its worst viewer's
// report. It goes down by a quarter when the report says the network cannot
// keep up (to no less than what reaches the viewer, unless that is much less),
// at most every ADAPT_CUT_EVERY. It goes up by a fifth of the configured
// bitrate after ADAPT_GOOD_FOR of good reports. It never goes below
// 1/ADAPT_FLOOR of the configured bitrate, nor above it.
//
// When the encoder's bitrate is known, changes start from it rather than from
// what was asked for last, which the library may have left alone as too small
// a change. While the encoder has not taken up the last change, and for
// ADAPT_SETTLE after it has, the reports are ignored.
adapt_bitrate :: proc(o: ^Video_Out, worst: proto.Video_Report, max_kbit: int, now: time.Tick) {
	if max_kbit <= 0 {
		return
	}
	floor := max(SHARE_KBIT_MIN, max_kbit / ADAPT_FLOOR)
	asked := o.target_kbit if o.target_kbit > 0 else max_kbit
	current := asked
	if enc := o.encoding_kbit; enc > 0 {
		// The library takes up a change of a fifth or more, and any change back
		// to the configured bitrate.
		pending :=
			asked != enc && (abs(asked - enc) * ADAPT_MIN_CHANGE >= enc || asked == max_kbit)
		if pending || time.tick_diff(o.encoding_at, now) < ADAPT_SETTLE {
			o.good_since = {}
			return
		}
		current = enc
	}
	target := current
	switch {
	case worst.loss >= ADAPT_LOSS_BAD || worst.delay_ms >= ADAPT_DELAY_BAD:
		o.good_since = {}
		if o.cut_at == {} || time.tick_diff(o.cut_at, now) >= ADAPT_CUT_EVERY {
			// What reaches them, unless that is only the trickle of a still
			// screen.
			base := min(target, max(worst.kbit, target / 2))
			target = max(floor, base * 3 / 4)
			o.cut_at = now
		}
	case worst.loss < ADAPT_LOSS_GOOD && worst.delay_ms < ADAPT_DELAY_GOOD:
		if o.good_since == {} {
			o.good_since = now
		} else if target < max_kbit && time.tick_diff(o.good_since, now) >= ADAPT_GOOD_FOR {
			target = min(max_kbit, target + max_kbit / 5)
			o.good_since = now
		}
	case:
		o.good_since = {} // in between: keep the current bitrate
	}
	// Asking again for what the library left alone would change nothing.
	if target != current && target != asked {
		log.infof(
			"video: %s bitrate %d -> %d kbit/s for our viewers (worst: %d/1000 lost, %d ms late)",
			stream_name(o.stream),
			current,
			target,
			worst.loss,
			worst.delay_ms,
		)
		o.target_kbit = target if target < max_kbit else 0
		video.share_adapt(o.stream, target)
	}
}
