package client

import log "../common/wlog"
import "core:fmt"
import "core:strings"
import "core:sync"
import mu "vendor:microui"

import "../proto"

/*
Server keys from the UI, rather than by editing known_servers (or, in a
browser, the page's local storage) by hand: the connect screen offers
to trust a server's new key when it has changed, and the settings page
lists the saved keys, each of which can be forgotten.

A changed key is either harmless (the server was set up again, or its
key file replaced) or someone in the middle pretending to be the server,
and the two look exactly the same from here. So neither place makes it
a one-click habit without saying so: the connect screen explains what a
change can mean and how to check it with whoever runs the server.
*/

UI_Known_Servers :: struct {
	// The settings page's copy of the file, read when the page is
	// opened (open_settings) and after a change, not every frame.
	list:   []Known_Server,
	loaded: bool,
}

WARNING_COLOR :: mu.Color{230, 200, 90, 255}
ERROR_COLOR :: mu.Color{230, 90, 90, 255}

// open_settings shows the settings page, with the saved keys read afresh.
open_settings :: proc(ui: ^UI) {
	ui.page = .Settings
	ui.known.loaded = false
}

known_servers_destroy :: proc(ui: ^UI) {
	for s in ui.known.list {
		delete(s.addr)
	}
	delete(ui.known.list)
	ui.known = {}
}

// grouped_key is a whole key in groups of 8 hex digits, for reading out
// and comparing; the first group is the fingerprint shown elsewhere.
grouped_key :: proc(key: [proto.KEY_SIZE]u8) -> string {
	full := key_hex(key)
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(full); i += 8 {
		if i > 0 {
			strings.write_byte(&b, ' ')
		}
		strings.write_string(&b, full[i:min(i + 8, len(full))])
	}
	return strings.to_string(b)
}

@(private = "file")
text_proc :: proc(ctx: ^mu.Context, text: string) {
	mu.text(ctx, text)
}

/*
key_change_panel is drawn on the connect screen, under the error, when
the last connection failed because the server's key has changed. Called
with the View locked.
*/
key_change_panel :: proc(ui: ^UI) {
	ctx := &ui.ctx
	kc := &ui.view.key_change

	mu.layout_row(ctx, {80, -1})
	mu.label(ctx, "Saved key")
	mu.label(ctx, grouped_key(kc.saved))
	mu.label(ctx, "New key")
	mu.label(ctx, grouped_key(kc.received))

	mu.layout_row(ctx, {-1})
	with_text_color(
		ctx,
		WARNING_COLOR,
		"A server's key normally stays the same. It changes when the server is set up again or its key file is replaced, but a changed key is also exactly what you would see if someone were intercepting the connection and pretending to be the server.",
		text_proc,
	)
	mu.text(
		ctx,
		`Only trust the new key if the person running the server confirms it changed. The server logs its key when it starts ("server public key: ..."), which should match the new key above.`,
	)

	mu.layout_row(ctx, {230, 130})
	if .SUBMIT in mu.button(ctx, "Trust the new key and connect") {
		ui.action = .Trust_Key
	}
	if .SUBMIT in mu.button(ctx, "Keep the old key") {
		log.debug("ui: keep the old server key")
		view_clear_key_change(&ui.view)
	}
}

// trust_new_key saves the key the server showed last time in place of
// the old one, then connects to it again. Runs between frames, like
// connect, with the View unlocked.
trust_new_key :: proc(ui: ^UI) {
	v := &ui.view
	server: string
	key: [proto.KEY_SIZE]u8
	{
		sync.guard(&v.mutex)
		if !v.key_change.changed {
			return
		}
		server = strings.clone(v.key_change.server, context.temp_allocator)
		key = v.key_change.received
	}

	if !replace_server_key(ui.opts.known_servers, server, key) {
		sync.guard(&v.mutex)
		delete(v.error)
		v.error = fmt.aprintf("Could not save the new key of %s.", server)
		return
	}
	log.infof("trusting the new key of %s: %s", server, key_hex(key))
	ui.known.loaded = false
	ui.server_len = copy(ui.server_buf[:], server)
	connect(ui)
}

// trusted_servers_settings is the settings page's list of saved server
// keys, each with a button to forget it.
trusted_servers_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	if !header(ctx, "Trusted servers") {
		return
	}
	k := &ui.known
	if !k.loaded {
		known_servers_destroy(ui)
		k.list = list_known_servers(ui.opts.known_servers)
		k.loaded = true
	}

	mu.layout_row(ctx, {-1})
	mu.text(
		ctx,
		"The key each server showed the first time you connected to it. If a server's key changes, yap won't connect to it until you trust the new one. Forgetting a key makes the next connection trust whatever key the server shows, so only forget one when you know why it changed.",
	)
	if len(k.list) == 0 {
		mu.label(ctx, "  None yet.")
		return
	}

	forget := -1
	for s, i in k.list {
		mu.push_id(ctx, uintptr(i))
		defer mu.pop_id(ctx)

		mu.layout_row(ctx, {-(80 + ctx.style.spacing), -1})
		mu.label(ctx, fmt.tprintf("%s   %s", s.addr, fingerprint(s.key)))
		if .SUBMIT in stable_button(ctx, "forget", "Forget") {
			forget = i
		}
	}
	// Not while going through the list, which this replaces.
	if forget >= 0 {
		addr := k.list[forget].addr
		if forget_server_key(ui.opts.known_servers, addr) {
			log.infof("forgot the key of %s", addr)
		}
		k.loaded = false
	}
}
