package ui

import txt "text"
import "core:fmt"
import "core:strconv"
import "core:strings"
import mu "vendor:microui"

import "client:script"

// The Scripts page: the scripts the client knows of (client/script), and for
// each what it says about itself, whether it runs, what it was allowed, for which
// servers, and its settings, which the script describes and this page draws.
//
// A script has to be approved before it runs: switching it on shows what it asks
// for, and the approval is for the text it has then (a script that has changed
// asks again). Everything on the page goes through the runtime, which checks it;
// the page works from a copy of what the runtime knows (runtime_snapshot), made
// every frame.

// A setting's text box or slider while it is edited.
Script_Field :: struct {
	buf:     [script.MAX_SETTING_STRING]u8,
	len:     int,
	slider:  f32,
	focused: bool, // in the last frame
	shown:   string, // the value it was last filled from (owned)
}

UI_Scripts :: struct {
	dir:       string, // where they are kept, for the page to say (owned)
	fields:    map[string]^Script_Field, // by "file/key" (owned keys)
	approving: string, // the script whose approval is open (owned)
	removing:  bool, // the delete button of that script is armed
	note:      string, // what the last action said, if it failed (owned)
	adding:    bool, // the form for a new script is open
	add_name:  Text_Field(48),
	add_text:  []u8, // MAX_SCRIPT_SIZE bytes, made when the form opens
	add_len:   int,
	add_area:  txt.Area,
}

scripts_ui_destroy :: proc(ui: ^UI) {
	su := &ui.script_ui
	for k, f in su.fields {
		delete(k)
		delete(f.shown)
		free(f)
	}
	delete(su.fields)
	delete(su.dir)
	delete(su.approving)
	delete(su.note)
	delete(su.add_text)
	su^ = {}
}

@(private = "file")
set_note :: proc(su: ^UI_Scripts, text: string) {
	delete(su.note)
	su.note = strings.clone(text)
}

script_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	su := &ui.script_ui
	rt := ui.scripts
	if rt == nil {
		mu.layout_row(ctx, {-1})
		dim_note(ctx, "  Scripts are not available: there is nowhere to keep them.")
		return
	}
	mu.layout_row(ctx, {-1})
	dim_note(
		ctx,
		"  Scripts are small Lua programs that run in this client: they can react to messages, add /commands, and change what is shown or sent. A script can see the messages of the servers it runs for, so switch on only those you trust.",
	)
	if su.dir != "" {
		mu.layout_row(ctx, {-1})
		dim_note(
			ctx,
			fmt.tprintf("  Put scripts (files ending in .lua) in %s, then press Reload.", su.dir),
		)
	}
	// Whether scripts can make web requests at all (on Linux that takes libcurl).
	http_ok, http_how := script.runtime_http_status(rt)
	mu.layout_row(ctx, {-1})
	if http_ok {
		dim_note(ctx, fmt.tprintf("  Web requests: available (%s).", http_how))
	} else {
		error_note(
			ctx,
			fmt.tprintf(
				"  Web requests are not available: %s. Scripts that need them will not work.",
				http_how,
			),
		)
	}
	mu.layout_row(ctx, {120, 120, -1})
	if .SUBMIT in button(ctx, "Reload") {
		script.runtime_reload(rt)
		scripts_forget_fields(su)
		set_note(su, "")
	}
	if .SUBMIT in button(ctx, "Add a script" if !su.adding else "Close") {
		su.adding = !su.adding
		if su.adding && su.add_text == nil {
			su.add_text = make([]u8, script.MAX_SCRIPT_SIZE)
		}
	}
	mu.layout_row(ctx, {-1})
	mu.label(ctx, "")
	if su.adding {
		script_add_form(ui)
	}
	if su.note != "" {
		mu.layout_row(ctx, {-1})
		error_note(ctx, fmt.tprintf("  %s", su.note))
	}

	views := script.runtime_snapshot(rt)
	if len(views) == 0 {
		mu.layout_row(ctx, {-1})
		dim_note(ctx, "  No scripts yet.")
		return
	}
	for v in views {
		script_card(ui, v)
	}
}

@(private = "file")
scripts_forget_fields :: proc(su: ^UI_Scripts) {
	for k, f in su.fields {
		delete(k)
		delete(f.shown)
		free(f)
	}
	clear(&su.fields)
}

// script_add_form adds a script from text that is pasted (or typed) in.
@(private = "file")
script_add_form :: proc(ui: ^UI) {
	ctx := &ui.ctx
	su := &ui.script_ui
	field_row(ui, 120, "File name", {-1})
	text_box(ui, su.add_name.buf[:], &su.add_name.len)
	mu.layout_row(ctx, {-1})
	dim_note(ctx, "  Letters, digits, _ and -, ending in .lua. Paste the script below.")
	su.add_area.min_lines = 8
	mu.layout_row(
		ctx,
		{-1},
		txt.area_height(ctx, ctx.style.font, string(su.add_text[:su.add_len]), &su.add_area),
	)
	text_area(ui, su.add_text, &su.add_len, &su.add_area)
	mu.layout_row(ctx, {120, -1})
	if .SUBMIT in button(ctx, "Save") {
		if err := script.runtime_add_source(
			ui.scripts,
			field_text(&su.add_name),
			string(su.add_text[:su.add_len]),
		); err != "" {
			set_note(su, err)
		} else {
			set_note(su, "")
			su.add_name.len, su.add_len, su.adding = 0, 0, false
		}
	}
}

@(private = "file")
script_card :: proc(ui: ^UI, v: script.Item_View) {
	ctx := &ui.ctx
	su := &ui.script_ui
	status := "off"
	switch {
	case v.running:
		status = "running"
	case v.changed:
		status = "needs a look"
	case v.problem != "":
		status = "can't run"
	}
	mu.push_id(ctx, v.file)
	defer mu.pop_id(ctx)
	mu.layout_row(ctx, {-1})
	if .ACTIVE not_in begin_treenode(ctx, fmt.tprintf("%s  (%s)", v.name, status)) {
		return
	}
	defer mu.end_treenode(ctx)

	if v.description != "" {
		mu.layout_row(ctx, {-1})
		wrap_text(ctx, v.description)
	}
	meta := v.file
	if v.version != "" {
		meta = fmt.tprintf("%s, version %s", meta, v.version)
	}
	if v.author != "" {
		meta = fmt.tprintf("%s, by %s", meta, v.author)
	}
	mu.layout_row(ctx, {-1})
	dim_note(ctx, meta)
	if v.problem != "" {
		mu.layout_row(ctx, {-1})
		error_note(ctx, v.problem)
	}
	for p in v.problems {
		mu.layout_row(ctx, {-1})
		dim_note(ctx, fmt.tprintf("get_info: %s", p))
	}

	// Running, and what it may do.
	asks := script_permissions_text(v.requested)
	mu.layout_row(ctx, {-1})
	dim_note(ctx, fmt.tprintf("Asks to: %s", asks))
	if v.enabled {
		mu.layout_row(ctx, {160, -1})
		if .SUBMIT in button(ctx, "Switch off") {
			script.runtime_set_enabled(ui.scripts, v.file, false)
		}
		mu.label(ctx, fmt.tprintf("Allowed: %s", script_permissions_text(v.granted)))
	} else if su.approving == v.file {
		mu.layout_row(ctx, {-1})
		wrap_text(
			ctx,
			fmt.tprintf(
				"This script will be able to: %s. It will also see the messages of the servers it runs for. It is approved as it is now; if it changes, you will be asked again.",
				asks,
			),
		)
		mu.layout_row(ctx, {160, 160, -1})
		if .SUBMIT in button(ctx, "Allow and switch on") {
			if err := script.runtime_set_enabled(ui.scripts, v.file, true, v.requested);
			   err != "" {
				set_note(su, err)
			} else {
				set_note(su, "")
			}
			delete(su.approving)
			su.approving = ""
		}
		if .SUBMIT in button(ctx, "Cancel") {
			delete(su.approving)
			su.approving = ""
		}
	} else if v.problem == "" || v.changed {
		mu.layout_row(ctx, {160, -1})
		if .SUBMIT in button(ctx, "Switch on...") {
			delete(su.approving)
			su.approving = strings.clone(v.file)
		}
	}

	script_scope(ui, v)
	for s in v.settings {
		script_setting(ui, v, s)
	}

	mu.layout_row(ctx, {160, -1})
	if confirm_button(
		ctx,
		&su.removing,
		fmt.tprintf("remove %s", v.file),
		"Delete script",
		"Really delete?",
	) {
		script.runtime_remove_source(ui.scripts, v.file)
		scripts_forget_fields(su)
	}
}

@(private = "file")
script_permissions_text :: proc(p: script.Permissions) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	if .Send in p {
		append(&parts, "send messages as you")
	}
	if .Notify in p {
		append(&parts, "show notifications and status text")
	}
	if .Net in p {
		append(&parts, "make web requests")
	}
	if len(parts) == 0 {
		return "nothing beyond reading and replying to events"
	}
	return strings.join(parts[:], ", ", context.temp_allocator)
}

// script_scope is the choice of servers a script runs for.
@(private = "file")
script_scope :: proc(ui: ^UI, v: script.Item_View) {
	ctx := &ui.ctx
	// A checkbox is known by the address of its bool, and these are locals, which
	// are all at the same place: each is given an id of its own.
	mu.push_id(ctx, "scope")
	defer mu.pop_id(ctx)
	all := v.all_servers
	mu.layout_row(ctx, {-1})
	changed := .CHANGE in checkbox(ctx, "Runs for all servers", &all)
	servers := make([dynamic]string, context.temp_allocator)
	append(&servers, ..v.servers)
	if changed && !all && len(servers) == 0 {
		// Starting from every server, to take some away.
		for joined in ui.settings.joined_servers {
			append(&servers, joined.address)
		}
	}
	if !all {
		for joined in ui.settings.joined_servers {
			on := script_scope_has(servers[:], joined.address)
			mu.layout_row(ctx, {20, -1})
			mu.label(ctx, "")
			mu.push_id(ctx, joined.address)
			defer mu.pop_id(ctx)
			if .CHANGE in checkbox(ctx, joined.address, &on) {
				changed = true
				if on {
					append(&servers, joined.address)
				} else {
					for s, i in servers {
						if strings.equal_fold(s, joined.address) {
							ordered_remove(&servers, i)
							break
						}
					}
				}
			}
		}
	}
	if changed {
		script.runtime_set_scope(ui.scripts, v.file, all, servers[:])
	}
}

@(private = "file")
script_scope_has :: proc(servers: []string, address: string) -> bool {
	for s in servers {
		if strings.equal_fold(s, address) {
			return true
		}
	}
	return false
}

// script_field is the text box and slider state of one setting.
@(private = "file")
script_field :: proc(su: ^UI_Scripts, file, key: string) -> ^Script_Field {
	name := fmt.tprintf("%s/%s", file, key)
	if f, ok := su.fields[name]; ok {
		return f
	}
	f := new(Script_Field)
	su.fields[strings.clone(name)] = f
	return f
}

@(private = "file")
script_setting :: proc(ui: ^UI, v: script.Item_View, s: script.Setting_View) {
	ctx := &ui.ctx
	su := &ui.script_ui
	def := s.def
	// See script_scope: one id per setting, whatever the address of its bool.
	mu.push_id(ctx, def.key)
	defer mu.pop_id(ctx)
	set :: proc(ui: ^UI, file, key: string, value: script.Value) {
		if err := script.runtime_set_value(ui.scripts, file, key, value); err != "" {
			set_note(&ui.script_ui, err)
		}
	}
	switch def.type {
	case .Bool:
		value, _ := s.value.(bool)
		mu.layout_row(ctx, {-1})
		if .CHANGE in checkbox(ctx, def.label, &value) {
			set(ui, v.file, def.key, value)
		}
	case .Choice:
		current := 0
		text, _ := s.value.(string)
		items := make([]Dropdown_Item, len(def.choices), context.temp_allocator)
		for c, i in def.choices {
			items[i] = {
				label = c,
			}
			if c == text {
				current = i
			}
		}
		field_row(ui, 160, def.label, {-1})
		if picked, ok := dropdown(
			ui,
			fmt.tprintf("script %s %s", v.file, def.key),
			text,
			items,
			current,
		); ok {
			set(ui, v.file, def.key, def.choices[picked])
		}
	case .Int, .Number:
		f := script_field(su, v.file, def.key)
		current: f64
		#partial switch n in s.value {
		case i64:
			current = f64(n)
		case f64:
			current = n
		}
		field_row(ui, 160, def.label, {-1})
		if def.has_min && def.has_max && def.max > def.min {
			if !slider_dragged(ctx, &f.slider) {
				f.slider = f32(current)
			}
			step: f32 = 1 if def.type == .Int else 0
			format := "%.0f" if def.type == .Int else "%.2f"
			if release_slider(ctx, &f.slider, f32(def.min), f32(def.max), step, format) {
				set(ui, v.file, def.key, i64(f.slider) if def.type == .Int else f64(f.slider))
			}
		} else {
			script_text_setting(
				ui,
				v,
				def,
				f,
				fmt.tprint(current),
				false,
				proc(ui: ^UI, v: script.Item_View, def: script.Setting_Def, text: string) {
					n, ok := strconv.parse_f64(strings.trim_space(text))
					if !ok {
						set_note(&ui.script_ui, fmt.tprintf("%s needs a number", def.label))
						return
					}
					if def.type == .Int {
						if err := script.runtime_set_value(ui.scripts, v.file, def.key, i64(n));
						   err != "" {
							set_note(&ui.script_ui, err)
						}
					} else if err := script.runtime_set_value(ui.scripts, v.file, def.key, n);
					   err != "" {
						set_note(&ui.script_ui, err)
					}
				},
			)
		}
	case .String:
		f := script_field(su, v.file, def.key)
		text, _ := s.value.(string)
		field_row(ui, 160, def.label, {-1})
		script_text_setting(
			ui,
			v,
			def,
			f,
			text,
			def.secret,
			proc(ui: ^UI, v: script.Item_View, def: script.Setting_Def, text: string) {
				if err := script.runtime_set_value(ui.scripts, v.file, def.key, text); err != "" {
					set_note(&ui.script_ui, err)
				}
			},
		)
	}
	if def.description != "" {
		mu.layout_row(ctx, {-1})
		dim_note(ctx, fmt.tprintf("  %s", def.description))
	}
}

// script_text_setting is a setting edited in a text box. What was typed is applied
// with Enter, or when the box loses the focus; until then the box keeps what is in
// it, and otherwise it follows the setting.
@(private = "file")
script_text_setting :: proc(
	ui: ^UI,
	v: script.Item_View,
	def: script.Setting_Def,
	f: ^Script_Field,
	value: string,
	secret: bool,
	apply: proc(ui: ^UI, v: script.Item_View, def: script.Setting_Def, text: string),
) {
	ctx := &ui.ctx
	id := mu.get_id(ctx, uintptr(&f.buf[0]))
	focused := ctx.focus_id == id
	if !focused && (f.shown != value || f.len == 0 && value != "") {
		n := min(len(value), len(f.buf))
		copy(f.buf[:n], value)
		f.len = n
		delete(f.shown)
		f.shown = strings.clone(value)
	}
	res := password_box(ui, f.buf[:], &f.len) if secret else text_box(ui, f.buf[:], &f.len)
	if .SUBMIT in res || (f.focused && !focused) {
		text := string(f.buf[:f.len])
		if text != f.shown {
			apply(ui, v, def, text)
			delete(f.shown)
			f.shown = strings.clone(text)
		}
	}
	f.focused = focused
}
