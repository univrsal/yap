package client

import "core:fmt"
import "core:strings"
import "core:time"
import mu "vendor:microui"
import "client:conn"

/*
The connection indicator: three bars rising left to right, like a
phone's signal. Three green for a good connection, two yellow for a
fair one, one red for a poor one, and none lit until there's anything
to go by (conn/ping.odin says which is which). Hovering over it shows the
numbers behind it.
*/

// The bars, in logical pixels: as wide as an icon, and as tall.
@(private = "file")
BAR_WIDTH :: 4
@(private = "file")
BAR_GAP :: 2
@(private = "file")
BAR_HEIGHTS := [3]i32{6, 11, 16}

FAIR_COLOR :: mu.Color{230, 200, 90, 255}
// A bar that isn't lit.
@(private = "file")
UNLIT_COLOR :: mu.Color{75, 75, 75, 255}

connection_indicator :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := &ui.view
	r := mu.layout_next(ctx)
	s := v.connection

	lit := 0
	color := UNLIT_COLOR
	switch s.quality {
	case .Unknown:
	case .Poor:
		lit, color = 1, OFF_COLOR
	case .Fair:
		lit, color = 2, FAIR_COLOR
	case .Good:
		lit, color = 3, SPEAKING_COLOR
	}

	width := i32(len(BAR_HEIGHTS)) * BAR_WIDTH + i32(len(BAR_HEIGHTS) - 1) * BAR_GAP
	tallest := BAR_HEIGHTS[len(BAR_HEIGHTS) - 1]
	x := r.x + (r.w - width) / 2
	bottom := r.y + (r.h + tallest) / 2
	for h, i in BAR_HEIGHTS {
		bar := mu.Rect{x + i32(i) * (BAR_WIDTH + BAR_GAP), bottom - h, BAR_WIDTH, h}
		mu.draw_rect(ctx, bar, color if i < lit else UNLIT_COLOR)
	}

	if mu.mouse_over(ctx, r) {
		ui.hint, ui.hint_of = connection_hint(v.status, s), r
		// The figures change with every ping, without waking the UI.
		ui_redraw_in(ui, conn.PING_INTERVAL)
	}
}

// connection_hint is the indicator's tooltip, one line per figure. It's
// in the temp allocator, which lasts the frame.
@(private = "file")
connection_hint :: proc(status: conn.Status, s: conn.Connection_Stats) -> string {
	if status != .Connected {
		return "Connecting..."
	}
	if s.quality == .Unknown {
		if s.sent == 0 {
			return "Measuring the connection..."
		}
		return fmt.tprintf("No answer to %d pings from the server", s.lost)
	}

	b := strings.builder_make(context.temp_allocator)
	quality: string
	#partial switch s.quality {
	case .Good:
		quality = "good"
	case .Fair:
		quality = "fair"
	case .Poor:
		quality = "poor"
	}
	fmt.sbprintf(&b, "Connection: %s\n", quality)
	fmt.sbprintf(&b, "Ping: %s (last %s)\n", ms(s.avg_rtt), ms(s.last_rtt))
	fmt.sbprintf(&b, "Range: %s to %s\n", ms(s.min_rtt), ms(s.max_rtt))
	fmt.sbprintf(&b, "Jitter: %s\n", ms(s.jitter))
	fmt.sbprintf(&b, "Packet loss: %.1f%% (%d of %d)", conn.connection_loss(s), s.lost, s.sent)
	if s.lost_run >= conn.LOST_IN_A_ROW {
		fmt.sbprintf(&b, "\nNo answer to the last %d pings", s.lost_run)
	}
	return strings.to_string(b)
}

// ms writes a round trip in milliseconds, with a decimal where they're
// few enough for it to matter (a server on the same network).
@(private = "file")
ms :: proc(d: time.Duration) -> string {
	m := time.duration_milliseconds(d)
	if m < 10 {
		return fmt.tprintf("%.1f ms", m)
	}
	return fmt.tprintf("%.0f ms", m)
}
