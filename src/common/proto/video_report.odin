package proto

import "core:encoding/endian"

/*
Report is how a share's bitrate follows what its viewers get, on the
media link. Each viewer says, once a second, how the share it watches
reaches it:

	client -> server  Report  [kind][sharer u32][loss u16][delay u16][kbit u32]

and the server passes the worst of them on to the sharer, once a
second, leaving out one that's far worse off than the rest (so one bad
connection doesn't drag everyone down):

	server -> sharer  Report  [kind][viewers u16][left out u16][loss u16][delay u16][kbit u32]

The sharer's client lowers its bitrate while that says the network
can't keep up, and raises it again, up to what it was set to, while it
can (conn/video.odin).
*/
REPORT_SIZE :: 1 + 4 + 2 + 2 + 4
#assert(REPORT_SIZE == 1 + 2 + 2 + 2 + 2 + 4) // both ways

Video_Report :: struct {
	// Fragments missing before any were asked for again, in thousandths
	// of those that came.
	loss:     int,
	// How much later than at their quickest frames have been arriving,
	// in milliseconds: a queue building up somewhere on the way.
	delay_ms: int,
	// What came in, in kbit/s.
	kbit:     int,
}

encode_report_up :: proc(out: ^[REPORT_SIZE]u8, sharer: User_Num, r: Video_Report) -> []u8 {
	out[0] = u8(Message_Kind.Report)
	endian.unchecked_put_u32le(out[1:], u32(sharer))
	endian.unchecked_put_u16le(out[5:], u16(clamp(r.loss, 0, 1000)))
	endian.unchecked_put_u16le(out[7:], u16(clamp(r.delay_ms, 0, 65535)))
	endian.unchecked_put_u32le(out[9:], u32(max(r.kbit, 0)))
	return out[:]
}

@(require_results)
decode_report_up :: proc(pt: []u8) -> (sharer: User_Num, r: Video_Report, ok: bool) {
	if len(pt) != REPORT_SIZE {
		return
	}
	sharer = User_Num(endian.unchecked_get_u32le(pt[1:]))
	r = {
		loss     = min(int(endian.unchecked_get_u16le(pt[5:])), 1000),
		delay_ms = int(endian.unchecked_get_u16le(pt[7:])),
		kbit     = int(endian.unchecked_get_u32le(pt[9:])),
	}
	return sharer, r, true
}

// The server's summary for a sharer: the worst of `viewers` reports,
// less `left_out` of them.
Video_Reports :: struct {
	viewers:  int,
	left_out: int,
	worst:    Video_Report,
}

encode_report_down :: proc(out: ^[REPORT_SIZE]u8, s: Video_Reports) -> []u8 {
	out[0] = u8(Message_Kind.Report)
	endian.unchecked_put_u16le(out[1:], u16(clamp(s.viewers, 0, 65535)))
	endian.unchecked_put_u16le(out[3:], u16(clamp(s.left_out, 0, 65535)))
	endian.unchecked_put_u16le(out[5:], u16(clamp(s.worst.loss, 0, 1000)))
	endian.unchecked_put_u16le(out[7:], u16(clamp(s.worst.delay_ms, 0, 65535)))
	endian.unchecked_put_u32le(out[9:], u32(max(s.worst.kbit, 0)))
	return out[:]
}

@(require_results)
decode_report_down :: proc(pt: []u8) -> (s: Video_Reports, ok: bool) {
	if len(pt) != REPORT_SIZE {
		return
	}
	s = {
		viewers = int(endian.unchecked_get_u16le(pt[1:])),
		left_out = int(endian.unchecked_get_u16le(pt[3:])),
		worst = {
			loss = min(int(endian.unchecked_get_u16le(pt[5:])), 1000),
			delay_ms = int(endian.unchecked_get_u16le(pt[7:])),
			kbit = int(endian.unchecked_get_u32le(pt[9:])),
		},
	}
	return s, true
}

/*
summarize_reports is what the server tells a sharer of its viewers'
reports: the worst, but with the single worst left out when there are
three or more and it's far behind the next (REPORT_OUTLIER_LOSS more
loss, or REPORT_OUTLIER_DELAY more delay). Its owner sees for itself
that it's losing frames; the rest keep their picture.
*/
REPORT_OUTLIER_LOSS :: 50 // thousandths
REPORT_OUTLIER_DELAY :: 200 // ms

summarize_reports :: proc(reports: []Video_Report) -> (s: Video_Reports) {
	s.viewers = len(reports)
	if len(reports) == 0 {
		return
	}
	// The worst and the next worst, by loss and then delay.
	worse :: proc(a, b: Video_Report) -> bool {
		return a.loss > b.loss || (a.loss == b.loss && a.delay_ms > b.delay_ms)
	}
	first, second := -1, -1
	for r, i in reports {
		if first < 0 || worse(r, reports[first]) {
			first, second = i, first
		} else if second < 0 || worse(r, reports[second]) {
			second = i
		}
	}
	skip := -1
	if len(reports) >= 3 {
		a, b := reports[first], reports[second]
		if a.loss - b.loss > REPORT_OUTLIER_LOSS ||
		   a.delay_ms - b.delay_ms > REPORT_OUTLIER_DELAY {
			skip = first
			s.left_out = 1
		}
	}
	s.worst.kbit = -1
	for r, i in reports {
		if i == skip {
			continue
		}
		s.worst.loss = max(s.worst.loss, r.loss)
		s.worst.delay_ms = max(s.worst.delay_ms, r.delay_ms)
		if s.worst.kbit < 0 || r.kbit < s.worst.kbit {
			s.worst.kbit = r.kbit
		}
	}
	return
}
