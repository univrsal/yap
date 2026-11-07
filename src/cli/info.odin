package main

import "core:fmt"
import "core:strings"

import "client:conn"
import "common:proto"
import "tui"

// Lists that commands ask the server for and the View then holds: the roles, the
// bans, the invites and our devices. A dialog shows them from the View as it
// changes, so they fill in when the answer comes.

Info_Kind :: enum {
	Roles,
	Bans,
	Invites,
	Devices,
}

@(private = "file")
INFO_TITLES := [Info_Kind]string {
	.Roles   = "Roles",
	.Bans    = "Bans",
	.Invites = "Invites",
	.Devices = "Your devices",
}

// open_info asks for a list and opens its dialog.
open_info :: proc(a: ^App, kind: Info_Kind) {
	switch kind {
	case .Roles: push(a, conn.Roles_Command{})
	case .Bans: push(a, conn.Bans_Command{})
	case .Invites: push(a, conn.Invites_Command{})
	case .Devices: push(a, conn.Devices_Command{})
	}
	dialog_close(a)
	a.dialog.kind, a.dialog.info = .Info, kind
}

// info_text is the list as text, one entry to a line. Call with the View locked.
info_text :: proc(v: ^conn.View, kind: Info_Kind) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	name_of :: proc(v: ^conn.View, id: proto.Account_Id) -> string {
		if acc, ok := v.accounts[id]; ok {
			return acc.display
		}
		return "someone"
	}
	switch kind {
	case .Roles:
		for r in v.roles {
			members := 0
			for _, acc in v.accounts {
				for id in acc.roles {
					members += 1 if id == r.id else 0
				}
			}
			fmt.sbprintfln(&b, "%s  %d member(s)  %s", r.name, members, perms_text(r.perms))
		}
	case .Bans:
		for ban in v.bans.list {
			fmt.sbprintfln(&b, "%s, by %s: %s", name_of(v, ban.account), name_of(v, ban.by), ban.reason if ban.reason != "" else "(no reason)")
		}
	case .Invites:
		if v.invites.made != "" {
			fmt.sbprintfln(&b, "Just made: %s", v.invites.made)
		}
		for inv in v.invites.list {
			uses := fmt.tprintf("%d", inv.uses) if inv.max_uses == 0 else fmt.tprintf("%d of %d", inv.uses, inv.max_uses)
			fmt.sbprintfln(&b, "%s  used %s  by %s%s", inv.code, uses, name_of(v, inv.creator), "  (revoked)" if inv.revoked else "")
		}
	case .Devices:
		for d in v.devices {
			state := ""
			if .Current in d.flags {
				state = "  (this one)"
			} else if .Online in d.flags {
				state = "  (online)"
			}
			fmt.sbprintfln(&b, "%s  %s%s", conn.fingerprint(d.key), d.name, state)
		}
	}
	return strings.to_string(b)
}

draw_info :: proc(a: ^App, b: ^tui.Buffer) {
	d := &a.dialog
	w, h := min(b.w - 4, 90), min(b.h - 2, 20)
	r := tui.Rect{(b.w - w) / 2, (b.h - h) / 2, w, h}
	append(&a.hits, Hit{r, .Dialog, 0, ""})
	draw_box(b, r, INFO_TITLES[d.info])
	text := info_text(a.view, d.info)
	if text == "" {
		text = "Nothing here (yet)."
	}
	lines := make([dynamic]tui.Line, context.temp_allocator)
	tui.wrap(strings.trim_right(text, "\n"), r.w - 4, &lines)
	for l, i in lines {
		if i >= r.h - 4 {
			break
		}
		tui.put_string(b, r.x + 2, r.y + 2 + i, text[l.start:l.end], {}, r.x + r.w - 1)
	}
	tui.put_string(b, r.x + 2, r.y + r.h - 2, "Any key closes", theme.dim, r.x + r.w - 1)
}

// perms_text lists permissions by name: "Invite, Pin_Messages".
perms_text :: proc(perms: proto.Permissions) -> string {
	names := make([dynamic]string, context.temp_allocator)
	for p in proto.Permission {
		if p in perms {
			append(&names, fmt.tprint(p))
		}
	}
	return strings.join(names[:], ", ", context.temp_allocator)
}
