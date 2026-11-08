package main

import "core:fmt"
import "core:strconv"
import "core:strings"

import "client:conn"
import "common:proto"
import "tui"

// Forms for what administrators do: a new channel, a channel's settings, a ban
// and an invite. A form has fields to fill in; submitting it sends what the
// matching /commands would (so the permissions are the server's to check).

Form_Kind :: enum {
	New_Channel,
	Channel_Settings,
	Ban_User,
	New_Invite,
}

FORM_TITLES := [Form_Kind]string {
	.New_Channel      = "New channel",
	.Channel_Settings = "Channel settings",
	.Ban_User         = "Ban someone",
	.New_Invite       = "New invite code",
}

Form_Field_Kind :: enum {
	Text,
	Toggle,
	Choice,
}

Form_Field :: struct {
	label:   string,
	kind:    Form_Field_Kind,
	edit:    tui.Editor, // for Text
	on:      bool, // for Toggle
	choice:  int, // for Choice
	choices: []string, // static
	hint:    string,
}

Form :: struct {
	kind:      Form_Kind,
	fields:    [dynamic]Form_Field,
	sel:       int,
	// What a channel was called and said before it was changed.
	channel:   proto.Conv_Id,
	name:      string, // owned
	topic:     string, // owned
	default:   bool,
	text_only: bool,
}

form_destroy :: proc(f: ^Form) {
	for &fl in f.fields {
		tui.editor_destroy(&fl.edit)
	}
	delete(f.fields)
	delete(f.name)
	delete(f.topic)
	f^ = {}
}

@(private = "file")
add_field :: proc(
	f: ^Form,
	label: string,
	kind: Form_Field_Kind,
	text := "",
	on := false,
	choices: []string = nil,
	hint := "",
) {
	fl := Form_Field {
		label   = label,
		kind    = kind,
		on      = on,
		choices = choices,
		hint    = hint,
	}
	if text != "" {
		tui.editor_set(&fl.edit, text)
	}
	append(&f.fields, fl)
}

PURGE_CHOICES := [?]string {
	"keep their messages",
	"remove the last hour",
	"remove the last day",
	"remove the last week",
	"remove all of them",
}

// open_form opens a form. Call with the View locked.
open_form :: proc(a: ^App, kind: Form_Kind) {
	dialog_close(a)
	a.dialog.kind = .Form
	f := &a.dialog.form
	f.kind = kind
	switch kind {
	case .New_Channel:
		add_field(f, "Name", .Text)
		add_field(f, "Topic", .Text)
		add_field(f, "Private", .Toggle, hint = "only those who are added see it")
		add_field(f, "For new members", .Toggle, hint = "new accounts join it")
		add_field(f, "Text only", .Toggle, hint = "no voice room")
	case .Channel_Settings:
		ch := conn.viewed_channel(a.view)
		if ch == nil {
			dialog_close(a)
			say(a, "Open a channel first.", true)
			return
		}
		f.channel, f.name, f.topic = ch.id, strings.clone(ch.name), strings.clone(ch.topic)
		f.default, f.text_only = .Default in ch.flags, .Text_Only in ch.flags
		add_field(f, "Name", .Text, ch.name)
		add_field(f, "Topic", .Text, ch.topic)
		add_field(f, "For new members", .Toggle, on = f.default)
		add_field(f, "Text only", .Toggle, on = f.text_only)
		add_field(f, "Archive it", .Toggle, hint = "deletes it, as far as anyone can tell")
	case .Ban_User:
		add_field(f, "Who", .Text, hint = "a user name")
		add_field(f, "Reason", .Text, hint = "they are told")
		add_field(f, "Messages", .Choice, choices = PURGE_CHOICES[:])
	case .New_Invite:
		add_field(f, "Uses", .Text, "1", hint = "0 for any number")
		add_field(f, "Valid for (days)", .Text, "7", hint = "0 for ever")
	}
}

@(private = "file")
text_of :: proc(f: ^Form, i: int) -> string {
	return strings.trim_space(tui.editor_text(&f.fields[i].edit))
}

// form_submit does what the form is for. It stays open, with a note, if
// something needed is missing.
form_submit :: proc(a: ^App) {
	f := &a.dialog.form
	switch f.kind {
	case .New_Channel:
		name := strings.trim_left(text_of(f, 0), "#")
		if name == "" {
			say(a, "The channel needs a name.", true)
			return
		}
		flags: proto.Conv_Flags
		if f.fields[3].on {flags += {.Default}}
		if f.fields[4].on {flags += {.Text_Only}}
		push(
			a,
			conn.Create_Channel_Command {
				name = strings.clone(name),
				topic = strings.clone(text_of(f, 1)),
				private = f.fields[2].on,
				flags = flags,
			},
		)
	case .Channel_Settings:
		// Only what changed is sent, as the commands for it.
		lines := make([dynamic]string, context.temp_allocator)
		if name := strings.trim_left(text_of(f, 0), "#"); name != f.name {
			if name == "" {
				say(a, "The channel needs a name.", true)
				return
			}
			append(&lines, fmt.tprintf("/rename %s", name))
		}
		if topic := text_of(f, 1); topic != f.topic {
			append(&lines, fmt.tprintf("/topic %s", topic))
		}
		if f.fields[2].on != f.default {
			append(&lines, fmt.tprintf("/default %s", "on" if f.fields[2].on else "off"))
		}
		if f.fields[3].on != f.text_only {
			append(&lines, fmt.tprintf("/textonly %s", "on" if f.fields[3].on else "off"))
		}
		if f.fields[4].on {
			append(&lines, "/archive")
		}
		conv := f.channel
		dialog_close(a)
		// The commands act on the channel being looked at.
		if a.viewing == conv {
			for l in lines {
				run_headless_command(a, l)
			}
		}
		return
	case .Ban_User:
		who := text_of(f, 0)
		if who == "" {
			say(a, "Who is to be banned?", true)
			return
		}
		reason := text_of(f, 1)
		line: string
		switch f.fields[2].choice {
		case 0:
			line = fmt.tprintf("/ban %s %s", who, reason)
		case 1:
			line = fmt.tprintf("/banpurge %s hour %s", who, reason)
		case 2:
			line = fmt.tprintf("/banpurge %s day %s", who, reason)
		case 3:
			line = fmt.tprintf("/banpurge %s week %s", who, reason)
		case:
			line = fmt.tprintf("/banpurge %s all %s", who, reason)
		}
		dialog_close(a)
		run_headless_command(a, strings.trim_space(line))
		return
	case .New_Invite:
		uses, ok1 := strconv.parse_int(text_of(f, 0))
		days, ok2 := strconv.parse_int(text_of(f, 1))
		if !ok1 || !ok2 || uses < 0 || days < 0 {
			say(a, "Uses and days are whole numbers.", true)
			return
		}
		dialog_close(a)
		run_headless_command(a, fmt.tprintf("/invite %d %d", uses, days))
		open_info(a, .Invites)
		return
	}
	dialog_close(a)
}

draw_form :: proc(a: ^App, b: ^tui.Buffer) {
	f := &a.dialog.form
	r := dialog_rect(b, 66, len(f.fields) * 2 + 6)
	append(&a.hits, Hit{r, .Dialog, 0, ""})
	draw_box(b, r, FORM_TITLES[f.kind])
	label_w := 0
	for fl in f.fields {
		label_w = max(label_w, tui.string_width(fl.label))
	}
	for &fl, i in f.fields {
		y := r.y + 2 + i * 2
		picked := i == f.sel
		tui.put_string(b, r.x + 2, y, fl.label, {attrs = {.Bold}} if picked else theme.dim)
		fx := r.x + 4 + label_w
		fw := r.x + r.w - 2 - fx
		style := theme.reaction if picked else tui.Style{bg = theme.reaction.bg}
		tui.fill(b, {fx, y, fw, 1}, style)
		switch fl.kind {
		case .Text:
			text := tui.editor_text(&fl.edit)
			tui.put_string(b, fx, y, tui.cut_to_width(text, fw - 1), style, fx + fw)
			if picked {
				a.cursor, a.cursor_shown = {fx + min(tui.string_width(text), fw - 1), y}, true
			}
			if text == "" && fl.hint != "" {
				tui.put_string(b, fx, y, fl.hint, {fg = theme.dim.fg, bg = style.bg}, fx + fw)
			}
		case .Toggle:
			tui.put_string(b, fx, y, "[x] yes" if fl.on else "[ ] no", style, fx + fw)
			if fl.hint != "" {
				tui.put_string(b, fx + 9, y, fl.hint, {fg = theme.dim.fg, bg = style.bg}, fx + fw)
			}
		case .Choice:
			tui.put_string(
				b,
				fx,
				y,
				fmt.tprintf("◂ %s ▸", fl.choices[fl.choice]),
				style,
				fx + fw,
			)
		}
		append(&a.hits, Hit{{r.x + 1, y, r.w - 2, 1}, .Form_Field, u64(i), ""})
	}
	tui.put_string(
		b,
		r.x + 2,
		r.y + r.h - 2,
		"Tab: next   Space / Left / Right: change   Enter: ok   Esc: cancel",
		theme.dim,
		r.x + r.w - 1,
	)
}

form_key :: proc(a: ^App, k: tui.Key_Event) {
	f := &a.dialog.form
	n := len(f.fields)
	fl := &f.fields[f.sel]
	switch {
	case k.key == .Escape:
		dialog_close(a)
	case k.key == .Enter:
		form_submit(a)
	case k.key == .Tab || k.key == .Down:
		f.sel = (f.sel + 1) % n
	case k.key == .Up:
		f.sel = (f.sel - 1 + n) % n
	case fl.kind == .Toggle &&
	     (k.key == .Left || k.key == .Right || k.key == .Rune && k.rune == ' '):
		fl.on = !fl.on
	case fl.kind == .Choice && k.key == .Left:
		fl.choice = (fl.choice - 1 + len(fl.choices)) % len(fl.choices)
	case fl.kind == .Choice && (k.key == .Right || k.key == .Rune && k.rune == ' '):
		fl.choice = (fl.choice + 1) % len(fl.choices)
	case fl.kind == .Text:
		tui.editor_key(&fl.edit, k)
	}
}
