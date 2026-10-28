package client

import "core:slice"
import "core:sync"
import mu "vendor:microui"

import "client:conn"
import "common:proto"

// Starting a group (see conn/buddies.odin): New group... at the top of the
// inbox's list, or Add people... in a DM's header, opens a window in which the
// others are picked: 2 to proto.MAX_GROUP_MEMBERS - 1 of them, found by name
// as in a channel's settings. Start opens the group of them (Group_Open), the
// existing one if there is one, and the inbox shows it as soon as the server
// has told us about it (see group_wanted_check). Nobody else sees the group
// until something is written in it.
//
// Bots can't be in a group, and the members of a group never change: adding
// someone is starting another group, while the first one goes on as it was.

UI_Group_Picker :: struct {
	open:    bool,
	placed:  bool,
	chosen:  [proto.MAX_GROUP_MEMBERS - 1]proto.Account_Id,
	count:   int,
	members: Pager,
	adding:  Pager,
}

@(private = "file")
GROUP_WINDOW :: "New group"

// open_group_picker opens the window for starting a group, with `with` (if
// not 0) picked already.
open_group_picker :: proc(ui: ^UI, with: proto.Account_Id = 0) {
	p := &ui.buddies.picker
	p^ = {
		open = true,
	}
	if with != 0 {
		p.chosen[0], p.count = with, 1
	}
}

// group_picker_window is the window in which a group's members are picked.
// Call with the View unlocked.
group_picker_window :: proc(ui: ^UI, window_w, window_h: i32) {
	p := &ui.buddies.picker
	if !p.open {
		return
	}
	ctx := &ui.ctx
	v := ui.view
	sync.guard(&v.mutex)
	if ui.session == nil || v.status != .Connected {
		p.open = false
		return
	}
	if !p.placed {
		p.placed = true
		w := clamp(window_w - 40, 260, 440)
		h := clamp(window_h - 40, 200, 480)
		if cnt := mu.get_container(ctx, GROUP_WINDOW); cnt != nil {
			cnt.rect = {(window_w - w) / 2, (window_h - h) / 2, w, h}
			cnt.open = true
			cnt.scroll = {}
			mu.bring_to_front(ctx, cnt)
			ctx.hover_root, ctx.next_hover_root = cnt, cnt
		}
	}
	if !mu.begin_window(ctx, GROUP_WINDOW, {}) {
		p.open = false
		return
	}
	keep_in_window(ui) // dragged: kept below the top bar, on screen
	defer mu.end_window(ctx)

	// Somebody who has gone (deleted, or made a bot) is taken out.
	for i := p.count - 1; i >= 0; i -= 1 {
		if !may_be_in_group(v, p.chosen[i]) {
			p.chosen[i] = p.chosen[p.count - 1]
			p.count -= 1
		}
	}
	chosen := p.chosen[:p.count]

	mu.layout_row(ctx, {-1})
	dim_label(ctx, "You and 2 to 7 others. Who is in a group can't be changed later.")
	mu.label(ctx, "")
	mu.label(ctx, "In it besides you")
	if p.count == 0 {
		mu.layout_row(ctx, {-1})
		dim_label(ctx, "  Nobody yet.")
	} else if out := people_list(ui, &p.members, chosen, "Take out", searched = true); out != 0 {
		if i, found := slice.linear_search(chosen, out); found {
			p.chosen[i] = p.chosen[p.count - 1]
			p.count -= 1
		}
	}

	mu.layout_row(ctx, {-1})
	mu.label(ctx, "")
	if p.count < len(p.chosen) {
		mu.label(ctx, "Add someone")
		others := make([dynamic]proto.Account_Id, context.temp_allocator)
		for id in v.accounts {
			if may_be_in_group(v, id) && !slice.contains(chosen, id) {
				append(&others, id)
			}
		}
		if add := people_finder(ui, &p.adding, others[:], "Add", .Plus); add != 0 {
			p.chosen[p.count] = add
			p.count += 1
			p.adding.find.len = 0
		}
	} else {
		dim_label(ctx, "That's as many as a group can have.")
	}

	mu.layout_row(ctx, {-1})
	mu.label(ctx, "")
	mu.layout_row(ctx, {-(100 + ctx.style.spacing + 1), 100})
	mu.label(ctx, "")
	if p.count < 2 {
		mu.label(ctx, "")
		return
	}
	if .SUBMIT in stable_button(ctx, "group start", "Start", {.ALIGN_CENTER}) {
		cmd := conn.Group_Command {
			count = p.count,
		}
		copy(cmd.accounts[:], chosen)
		command(ui, cmd)
		// Shown as soon as the server has told us about it.
		want: Group_Members
		want.count = copy(want.accounts[:], chosen)
		slice.sort(want.accounts[:want.count])
		ui.buddies.group_wanted = want
		ui.buddies.group_wanted_ns = ui.session
		mu.get_current_container(ctx).open = false
		p.open = false
	}
}

// may_be_in_group is whether an account can be picked for a group: somebody
// else who is neither a bot nor deleted nor disabled. Call with the View locked.
@(private = "file")
may_be_in_group :: proc(v: ^conn.View, id: proto.Account_Id) -> bool {
	acc, known := v.accounts[id]
	return known && id != v.me && acc.flags & {.Bot, .Deleted, .Disabled} == {}
}

// Group_Members are the others in a group, in ascending order.
Group_Members :: struct {
	accounts: [proto.MAX_GROUP_MEMBERS - 1]proto.Account_Id,
	count:    int,
}

// group_wanted_check opens the group that was just started in the inbox once the
// server has told us about it. Call with the View locked.
group_wanted_check :: proc(ui: ^UI) {
	b := &ui.buddies
	if b.group_wanted.count == 0 || b.group_wanted_ns != ui.session {
		return
	}
	want := b.group_wanted
	for &dm in ui.view.dms {
		if slice.equal(conn.group_members(&dm), want.accounts[:want.count]) {
			open_group(ui, dm.id)
			b.group_wanted = {}
			return
		}
	}
}
