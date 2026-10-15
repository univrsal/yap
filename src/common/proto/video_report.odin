package proto

import "core:encoding/endian"

// Reports let a share's bitrate follow what its viewers actually receive, on
// the media link. Once a second, each viewer reports how well the share it
// watches reaches it:
//
//	client -> server  Report  [kind][sharer u32][loss u16][delay u16][kbit u32]
//
// and once a second the server passes the worst of them on to the sharer.
// It leaves out a report that is far worse than the rest, so that one bad
// connection doesn't drag everyone down:
//
//	server -> sharer  Report  [kind][viewers u16][left out u16][loss u16][delay u16][kbit u32]
//
// The sharer's client lowers its bitrate while the report says that the
// network can't keep up, and raises it again, up to the configured bitrate,
// as long as it can (conn/video.odin).
REPORT_SIZE :: 1 + 4 + 2 + 2 + 4
#assert(REPORT_SIZE == 1 + 2 + 2 + 2 + 2 + 4) // both ways

Video_Report :: struct {
	// Fragments that were missing before any were requested again, in
	// thousandths of the fragments that arrived.
	loss:     int,
	// How much later than their fastest arrival frames have been arriving,
	// in milliseconds. A growing delay indicates a queue building up
	// somewhere along the way.
	delay_ms: int,
	// The received bitrate in kbit/s.
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

// The server's summary for a sharer: the worst of `viewers` reports, not
// counting `left_out` of them.
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

// summarize_reports is what the server tells a sharer about its viewers'
// reports: the worst one. If there are three or more reports and the single
// worst is far behind the next one (REPORT_OUTLIER_LOSS more loss, or
// REPORT_OUTLIER_DELAY more delay), it is left out. That viewer can see for
// themselves that they are losing frames, and the others keep their picture.
REPORT_OUTLIER_LOSS :: 50 // thousandths
REPORT_OUTLIER_DELAY :: 200 // ms

summarize_reports :: proc(reports: []Video_Report) -> (s: Video_Reports) {
	s.viewers = len(reports)
	if len(reports) == 0 {
		return
	}
	// Find the worst and the second worst report, ordered by loss and then by
	// delay.
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
