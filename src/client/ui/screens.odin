package ui

import "base:intrinsics"
import "client:render"
import "client:video"
import "core:fmt"
import "core:math"
import "core:sync"
import "core:time"
import mu "vendor:microui"

main_window :: proc(ui: ^UI) {
	// Joining a server from the + page (see ui/join.odin), which is all there is
	// when there is no server to show.
	if ui.join.open || (ui.session != nil && ui.session.joining) {
		join_page(ui)
		return
	}
	if ui.page == .Settings {
		settings_page(ui)
		return
	}
	if ui.session == nil {
		join_page(ui)
		return
	}

	// Every server's part of the inbox, with each View locked in turn, before
	// the shown server's part for the frame.
	ui.inbox = inbox_list(ui) if ui.page == .Buddies else nil
	v := ui.view
	sync.guard(&v.mutex)
	apply_gains(ui)
	switch v.status {
	case .Disconnected, .Failed:
		// The buddy screen goes away with the connection.
		if ui.page == .Buddies {
			ui.page = .Main
		}
		connect_screen(ui)
	case .Connecting, .Connected:
		// A server that doesn't know this device shows nothing until the device is
		// logged in (see ui/account.odin), and neither does a server whose password was
		// chosen by somebody else, until it has been replaced.
		switch {
		case v.status == .Connected && v.login.state != .Done:
			ui.page = .Main
			login_screen(ui)
		case v.status == .Connected && v.login.must_change:
			ui.page = .Main
			password_screen(ui)
		case v.status == .Connected && v.login.unverified:
			ui.page = .Main
			verify_screen(ui)
		case ui.page == .Buddies:
			buddies_screen(ui)
		case:
			session_screen(ui)
		}
	}
}

// connect_screen shows a server on the rail that isn't connected, in a card:
// what went wrong, when it will be tried again, the trust prompt if its key has
// changed, and buttons to try again now or to leave it.
@(private = "file")
connect_screen :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := ui.view
	card_begin(ui, "connect card", ui.connect_card_h)
	defer card_end(ui, &ui.connect_card_h)

	server := ui.session.server
	card_heading(ui, v.server_name if v.server_name != "" else server)
	mu.layout_row(ctx, {-1})
	switch {
	case v.status == .Failed && v.error != "":
		error_note(ctx, v.error)
	case v.status == .Failed:
		with_text_color(ctx, theme.error, "Could not connect.", mu.text)
	case:
		with_text_color(ctx, theme.dim, "Not connected.", mu.text)
	}
	if v.retrying {
		mu.layout_row(ctx, {-1})
		if v.retry_at == {} {
			with_text_color(ctx, theme.dim, "Connecting...", mu.text)
		} else {
			// Counted down one second at a time.
			left := time.tick_diff(time.tick_now(), v.retry_at)
			secs := max(int(math.ceil(time.duration_seconds(left))), 1)
			with_text_color(ctx, theme.dim, fmt.tprintf("Trying again in %ds.", secs), mu.text)
			ui_redraw_in(ui, left - time.Duration(secs - 1) * time.Second)
		}
	}
	key_change := v.status == .Failed && v.key_change.changed
	if key_change {
		key_change_panel(ui)
	}
	mu.layout_row(ctx, {-1}, ctx.style.spacing)
	mu.layout_next(ctx)
	mu.layout_row(ctx, {-1})
	// With a changed key, trusting the new key is what connects again.
	if !key_change && .SUBMIT in button(ctx, "Reconnect") {
		ui.action = .Reconnect
	}
	if .SUBMIT in button(ctx, "Leave this server") {
		ui.action = .Disconnect
	}
}

@(private = "file")
session_screen :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := ui.view
	body := mu.get_current_container(ctx).body
	narrow := ui.narrow
	ui.profiles.members_pinned = body.w >= MEMBERS_PIN_LAYOUT

	screen_tab_follow(ui)
	camera_tab_follow(ui)
	back_from_dms(ui)
	if camera_fullscreen(ui) {
		camera_full_screen(ui)
		return
	}
	if v.watching != 0 && video.is_fullscreen() {
		fullscreen_screen(ui)
		return
	}

	// A narrow window has no header of its own, except where the window's
	// buttons are among the content and the chat's own header would run into them.
	if !narrow || titlebar_merged(ui) {
		session_header(ui)
	}

	// Side by side where there is room. In a narrow window the list and
	// the chat take turns (see ui/channels.odin), over the voice panel if it
	// has anything to show.
	if narrow {
		mu.layout_row(ctx, {-1}, -(voice_panel_height(ui) + 1))
		if ui.channels.show_list {
			channel_list(ui)
		} else {
			surface := content_surface(ui)
			side_panel(ui, narrow)
			conversation_lines(ui, surface, false)
		}
		voice_panel(ui)
	} else {
		if ui.profiles.members_pinned {
			// -1 would leave the last cell no room, so the chat's cell
			// keeps the members' width (and the gap before it) free.
			mu.layout_row(
				ctx,
				{280, -(MEMBERS_PANEL_WIDTH + ctx.style.spacing + 1), MEMBERS_PANEL_WIDTH},
				-1,
			)
		} else {
			mu.layout_row(ctx, {280, -1}, -1)
		}
		channel_list(ui)
		surface := content_surface(ui)
		side_panel(ui, narrow)
		if ui.profiles.members_pinned {
			header_surface(ui, surface)
			members_panel(ui)
		}
		conversation_lines(ui, surface, ui.profiles.members_pinned)
	}
	user_menu(ui)
	channel_menu(ui)
	message_menu(ui)
	app_audio_menu(ui)
	share_menu(ui)
}

// session_header is the row along the top while connected, showing the server
// or the inbox. The session screen and the inbox share it. The connection's
// status and the settings are at the bottom of the rail
// (see rail_bottom). Mute, deafen and what is shared are in the voice panel
// (see ui/voice_panel.odin).
//
// It is only there with the title bar merged (titlebar_merged), where the row
// is taken anyway by the window's buttons. Otherwise the window's own title
// says the same (servers_frame), and the row is left to the chat, unless there
// is something to say about connecting.
session_header :: proc(ui: ^UI) {
	ctx := &ui.ctx
	v := ui.view
	if !titlebar_merged(ui) && (ui.page == .Buddies || v.status == .Connected) {
		return
	}
	title_row(ui, {-1})
	switch {
	case ui.page == .Buddies:
		opts := mu.Options{.ALIGN_CENTER}
		mu.draw_control_text(ctx, "Direct messages", mu.layout_next(ctx), .TEXT, opts)
	case v.status == .Connected:
		server := v.server_name if v.server_name != "" else v.server
		opts := mu.Options{.ALIGN_CENTER}
		mu.draw_control_text(ctx, fmt.tprintf("%s", server), mu.layout_next(ctx), .TEXT, opts)
	case:
		mu.label(ctx, fmt.tprintf("Connecting to %s...", v.server))
	}
}

// How tightly log lines are packed: exactly LINE_HEIGHT tall, instead of the
// couple of pixels of slack the default control size has, and with a tighter
// gap between rows than the rest of the UI uses, so more of the log
// fits on screen at once.
@(private = "file")
LOG_LINE_SPACING :: 1

log_panel :: proc(ui: ^UI) {
	ctx := &ui.ctx
	logs := ui.opts.logs

	mu.begin_panel(ctx, "log")
	cnt := mu.get_current_container(ctx)
	select_begin(ui, .Log)
	total: int
	{
		// No logging in here, because the log sink takes this same lock.
		sync.guard(&logs.mutex)
		total = logs.total
		ui.log_drawn = total // for frame_due to look out for more

		saved_spacing := ctx.style.spacing
		ctx.style.spacing = LOG_LINE_SPACING
		defer ctx.style.spacing = saved_spacing

		font := render.font_with_style(ctx.style.font, .Mono)
		// A line too long for the panel is wrapped, as the chat wraps it, and
		// goes on below, indented as far as the time at its start (but no
		// more than a third of the width, in a narrow window).
		width := cnt.body.w - ctx.style.padding * 4
		indent := min(ctx.text_width(font, "00:00:00.000 "), width / 3)
		// Lines are numbered by the running total, so a selection stays
		// on the same lines as new lines come in (see ui/select.odin).
		first := i64(logs.total - len(logs.lines))
		for line, i in logs.lines {
			// Drop the date, because the time is enough on screen.
			text := line.text[11:] if len(line.text) > 11 else line.text
			color := ctx.style.colors[.TEXT]
			switch {
			case line.level >= .Error:
				color = theme.error
			case line.level >= .Warning:
				color = theme.warning
			case line.level < .Info:
				color = theme.dim
			}
			item := first + i64(i)
			select_item(ui, item, text)
			// One row for each part of the line, the whole of it if it fits
			// (which is measured first, as most lines do).
			start, x := 0, i32(0)
			for {
				end, next := len(text), len(text)
				if ctx.text_width(font, text[start:]) > width - x {
					e, n := wrap_line(ctx, font, text[start:], width - x)
					end, next = start + e, start + n
				}
				mu.layout_row(ctx, {-1}, render.LINE_HEIGHT)
				// Where mu.label would put it.
				r := mu.layout_next(ctx)
				pos := mu.Vec2 {
					r.x + ctx.style.padding + x,
					r.y + (r.h - ctx.text_height(font)) / 2,
				}
				select_line(ui, item, text, start, end, pos, font = font)
				mu.draw_text(ctx, font, text[start:end], pos, color)
				if next >= len(text) {
					break
				}
				start, x = next, indent
			}
		}
	}
	select_end(ui)
	mu.end_panel(ctx)
}
