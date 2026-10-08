package client

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode/utf8"
import mu "vendor:microui"

import "client:conn"
import "common:proto"

/*
Forwarding and links (src/common/proto/forward.odin).

Forward... in a message's menu opens a window of where it can go: our
channels and our DMs, which a box narrows down by name; picking one
sends the copy there. A copy shows in its header whom it's from and
where (the timeline's header line).

Copy link in the menu puts the message's link token on the clipboard,
to paste into a message. A link shows as the message it points at,
"↪ Ana: what she said", fetched by id the way a thread's root is; or
"a message you can't see" when it isn't ours to read. Clicking one goes
to the message: in this conversation, or in its channel or DM.
*/

UI_Forward :: struct {
	open:        bool,
	placed:      bool,
	msg:         proto.Msg_Id,
	filter_buf:  [proto.MAX_CHANNEL_NAME_SIZE]u8,
	filter_len:  int,
	// Linked messages asked for, and when: asked again a while later if
	// they haven't come (the network side lets them go with their
	// conversation's window, and asking twice is one asking there).
	links_asked: map[proto.Msg_Id]time.Tick,
	// A link clicked this frame, gone to after it.
	go_conv:     proto.Conv_Id,
	go_id:       proto.Msg_Id,
}

@(private = "file")
FORWARD_WINDOW :: "Forward to"

ui_forward_destroy :: proc(ui: ^UI) {
	delete(ui.forward.links_asked)
	ui.forward = {}
}

// open_forward opens the window for forwarding message `id`.
open_forward :: proc(ui: ^UI, id: proto.Msg_Id) {
	f := &ui.forward
	f.open, f.placed, f.msg, f.filter_len = true, false, id, 0
}

/*
forward_window is where a message is forwarded to: our channels, then
our DMs, those whose name has what's typed in the box. Call with the
View unlocked.
*/
forward_window :: proc(ui: ^UI, window_w, window_h: i32) {
	f := &ui.forward
	if !f.open {
		return
	}
	ctx := &ui.ctx
	v := ui.view
	sync.guard(&v.mutex)
	if ui.session == nil || v.status != .Connected {
		f.open = false
		return
	}
	if !f.placed {
		f.placed = true
		w := clamp(window_w - 40, 240, 400)
		h := clamp(window_h - 40, 160, 420)
		if cnt := mu.get_container(ctx, FORWARD_WINDOW); cnt != nil {
			cnt.rect = {(window_w - w) / 2, (window_h - h) / 2, w, h}
			cnt.open = true
			cnt.scroll = {}
			mu.bring_to_front(ctx, cnt)
			ctx.hover_root, ctx.next_hover_root = cnt, cnt
		}
	}
	if !mu.begin_window(ctx, FORWARD_WINDOW, {}) {
		f.open = false
		return
	}
	defer mu.end_window(ctx)

	mu.layout_row(ctx, {-1})
	text_box(ui, f.filter_buf[:], &f.filter_len)
	filter := strings.to_lower(
		strings.trim_space(string(f.filter_buf[:f.filter_len])),
		context.temp_allocator,
	)
	row :: proc(ui: ^UI, conv: proto.Conv_Id, name, filter: string) -> bool {
		if filter != "" &&
		   !strings.contains(strings.to_lower(name, context.temp_allocator), filter) {
			return false
		}
		ctx := &ui.ctx
		mu.push_id(ctx, uintptr(conv))
		defer mu.pop_id(ctx)
		mu.layout_row(ctx, {-(90 + ctx.style.spacing + 1), 90})
		mu.label(ctx, name)
		if .SUBMIT in stable_button(ctx, "forward", "Send here", {.ALIGN_CENTER}) {
			conn.push_command(
				&ui.session.client.commands,
				conn.Forward_Command{msg = ui.forward.msg, conv = conv},
			)
			mu.get_current_container(ctx).open = false
			ui.forward.open = false
			return true
		}
		return false
	}
	for ch in v.channels {
		if row(ui, ch.id, fmt.tprintf("# %s", ch.name), filter) {
			return
		}
	}
	for dm in v.dms {
		name := "someone"
		if acc, ok := v.accounts[dm.with]; ok {
			// Not to be written to (ui_buddies.odin).
			if .Deleted in acc.flags {
				continue
			}
			name = acc.display
		}
		if row(ui, dm.id, name, filter) {
			return
		}
	}
}

/*
go_to_message shows message `id` of conversation `conv`: the timeline
goes to it once it's that conversation's, which it's switched to if it
isn't. Call with the View locked.
*/
go_to_message :: proc(ui: ^UI, conv: proto.Conv_Id, id: proto.Msg_Id) {
	v := ui.view
	st := &ui.timeline
	st.jump_to, st.jump_asked, st.jump_conv = id, false, conv
	if conv == v.viewing || ui.session == nil {
		return
	}
	for ch in v.channels {
		if ch.id == conv {
			ui.page = .Main
			conn.push_command(&ui.session.client.commands, conn.View_Command{conv = conv})
			return
		}
	}
	for dm in v.dms {
		if dm.id == conv {
			open_conversation(ui, dm.with)
			return
		}
	}
}

// links_after_frame goes where a link clicked in the frame points.
links_after_frame :: proc(ui: ^UI) {
	f := &ui.forward
	if f.go_id == 0 {
		return
	}
	sync.guard(&ui.view.mutex)
	go_to_message(ui, f.go_conv, f.go_id)
	f.go_conv, f.go_id = 0, 0
}

// is_ours is whether a conversation is one of ours: we can read it.
@(private = "file")
is_ours :: proc(v: ^conn.View, conv: proto.Conv_Id) -> bool {
	for ch in v.channels {
		if ch.id == conv {
			return true
		}
	}
	for dm in v.dms {
		if dm.id == conv {
			return true
		}
	}
	return false
}

// How long a linked message that hasn't come is waited for before it's
// asked for again.
@(private = "file")
LINK_ASK_AGAIN :: 3 * time.Second

// How much of a linked message a link shows.
@(private = "file")
LINK_SNIPPET :: 60

/*
link_label is how a link shows (conn.text_display_links): the message
it points at, by whom and its first words; or that it's on its way, or
isn't ours to see. The message is asked for the first time it's wanted.
`data` is the UI. Call with the View locked.
*/
link_label :: proc(data: rawptr, l: proto.Msg_Link) -> string {
	ui := (^UI)(data)
	v := ui.view
	if root, ok := v.roots[l.id]; ok {
		m := root.msg
		name := "someone"
		if acc, known := v.accounts[m.sender]; known {
			name = acc.display
		}
		said: string
		switch {
		case .Deleted in m.flags:
			return "↪ a deleted message"
		case m.kind == .Image:
			said = "a picture"
		case m.kind == .File:
			said = fmt.tprintf("the file %s", m.text)
		case m.kind == .System:
			said = "a call"
		case:
			said, _, _ = conn.text_display(m.text, v.accounts, v.me, v.emoji.names[:])
			said = conn.markdown_plain(said)
			if len(said) > LINK_SNIPPET {
				cut := LINK_SNIPPET
				for cut > 0 && !utf8.rune_start(said[cut]) {
					cut -= 1
				}
				said = fmt.tprintf("%s...", said[:cut])
			}
		}
		return fmt.tprintf("↪ %s: %s", name, said)
	}
	if v.roots_missing[l.id] || !is_ours(v, l.conv) {
		return "↪ a message you can't see"
	}
	f := &ui.forward
	asked, was := f.links_asked[l.id]
	if (!was || time.tick_since(asked) > LINK_ASK_AGAIN) && ui.session != nil {
		asked = time.tick_now()
		f.links_asked[l.id] = asked
		conn.push_command(
			&ui.session.client.commands,
			conn.Root_Command{conv = l.conv, root = l.id},
		)
	}
	// To ask again, should no answer come.
	if asked != {} {
		ui_redraw_at(ui, time.tick_add(asked, LINK_ASK_AGAIN + time.Millisecond))
	}
	return conn.LINK_TEXT
}

// message_text is a message's text as the timeline shows it: mentions,
// the server's emoji and links. Call with the View locked.
message_text :: proc(
	ui: ^UI,
	text: string,
) -> (
	shown: string,
	spans: []conn.Mention_Span,
	emoji: []conn.Emoji_Span,
	links: []conn.Link_Span,
) {
	v := ui.view
	return conn.text_display_links(text, v.accounts, v.me, v.emoji.names[:], link_label, ui)
}

// message_rich is a message's text as the timeline draws it: its markdown
// and web links too (ui_rich_text.odin). Call with the View locked.
message_rich :: proc(ui: ^UI, text: string) -> Rich {
	shown, spans, emoji, links := message_text(ui, text)
	return rich_make(shown, spans, emoji, links, true)
}

// forward_note is what a forwarded message's header says of where it
// came from: whom, and where if that's one of ours. Call with the View
// locked.
forward_note :: proc(ui: ^UI, m: conn.View_Message) -> string {
	if .Forwarded not_in m.flags {
		return ""
	}
	v := ui.view
	name := "someone"
	if acc, ok := v.accounts[m.forward.sender]; ok {
		name = acc.display
	}
	for ch in v.channels {
		if ch.id == m.forward.conv {
			return fmt.tprintf("  ↪ forwarded from %s in #%s", name, ch.name)
		}
	}
	return fmt.tprintf("  ↪ forwarded from %s", name)
}
