package client

import "client:conn"
import "client:render"
import "common:memtrack"
import log "common:wlog"
import "core:fmt"
import "core:strings"
import "core:time"
import mu "vendor:microui"

/*
Where the memory goes (common/memtrack, which main installs as the
allocator): this client's, on the settings page's Memory category, and
for a server's owner the server's, on the server tab's. Both are the
same report - the process's numbers beside what's counted, by file and
by line - and the client's also has the GPU's textures, which nothing
else counts.

A line about the client's goes in the log every MEMORY_LOG_EVERY too, so
a long run leaves a trend behind (-log-file keeps it).
*/

UI_Memory :: struct {
	logged:       time.Tick, // the last line in the log
	// The client's report, as of `taken`; owned. Taken again every
	// MEMORY_REFRESH while it's on screen.
	report:       string,
	taken:        time.Tick,
	// What "Give back" did, to say beside it.
	released:     string,
	// The server's has been asked for since the settings were opened.
	server_asked: bool,
}

@(private = "file")
MEMORY_LOG_EVERY :: time.Hour
@(private = "file")
MEMORY_REFRESH :: 2 * time.Second

ui_memory_opened :: proc(ui: ^UI) {
	ui.memory.server_asked = false
}

ui_memory_destroy :: proc(ui: ^UI) {
	delete(ui.memory.report)
	delete(ui.memory.released)
	ui.memory.report, ui.memory.released = "", ""
}

// memory_frame logs the line about the client's memory when it's time.
memory_frame :: proc(ui: ^UI) {
	m := &ui.memory
	if m.logged == {} {
		m.logged = time.tick_now()
	}
	if time.tick_since(m.logged) < MEMORY_LOG_EVERY {
		return
	}
	m.logged = time.tick_now()
	log.info(memtrack.summary(memory_extras(), context.temp_allocator))
}

// memory_extras is what the client has that memtrack doesn't see.
@(private = "file")
memory_extras :: proc() -> []memtrack.Extra {
	bytes, count := render.texture_memory()
	out := make([]memtrack.Extra, 1, context.temp_allocator)
	out[0] = {
		name   = "GPU textures (roughly)",
		bytes  = bytes,
		detail = fmt.tprintf("%d textures", count),
	}
	return out
}

// memory_settings is the client's Memory category.
memory_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	m := &ui.memory
	if m.report == "" || time.tick_since(m.taken) >= MEMORY_REFRESH {
		delete(m.report)
		m.report = memtrack.report(memory_extras())
		m.taken = time.tick_now()
	}
	ui_redraw_at(ui, time.tick_add(m.taken, MEMORY_REFRESH))

	mu.layout_row(ctx, {120, 120, -1})
	if .SUBMIT in mu.button(ctx, "Give back") {
		before := memtrack.process()
		if memtrack.release_free() {
			after := memtrack.process()
			delete(m.released)
			m.released = fmt.aprintf(
				"Resident %s, was %s.",
				memtrack.bytes_string(after.resident),
				memtrack.bytes_string(before.resident),
			)
		} else {
			delete(m.released)
			m.released = strings.clone("There's no way to on this system.")
		}
		m.taken = {}
	}
	if .SUBMIT in mu.button(ctx, "Write to log") {
		log.infof("memory:\n%s", memtrack.log_text(m.report, context.temp_allocator))
	}
	with_text_color(ctx, theme.dim, m.released, label_proc)
	mu.layout_row(ctx, {-1})
	with_text_color(
		ctx,
		theme.dim,
		"Give back returns heap free's pages to the system: resident drops, malloc still lists them.",
		label_proc,
	)
	memory_report(ui, m.report)
}

/*
server_memory_settings is the server tab's Memory category, for the
owner. Asked for when it's first shown, and again with Refresh. Call
with the View locked.
*/
server_memory_settings :: proc(ui: ^UI, v: ^conn.View) {
	ctx := &ui.ctx
	m := &ui.memory
	if !m.server_asked {
		m.server_asked = true
		command(ui, conn.Server_Memory_Command{})
	}
	mu.layout_row(ctx, {120, -1})
	if .SUBMIT in mu.button(ctx, "Refresh") {
		command(ui, conn.Server_Memory_Command{})
	}
	sm := &v.server_memory
	switch {
	case sm.count == 0:
		with_text_color(ctx, theme.dim, "Asking...", label_proc)
	case sm.status == .Unknown_Op:
		with_text_color(ctx, theme.dim, "This server is too old to say.", label_proc)
	case sm.status != .Ok:
		with_text_color(ctx, theme.error, conn.status_text(sm.status), label_proc)
	case:
		mu.label(ctx, "")
	}
	if sm.count > 0 && sm.status == .Ok {
		memory_report(ui, sm.report)
	}
}

@(private = "file")
command :: proc(ui: ^UI, cmd: conn.Command) {
	if ui.session != nil {
		conn.push_command(&ui.session.client.commands, cmd)
	}
}

/*
memory_report shows a report (memtrack's text): headings, and rows of
an amount, a detail and what it's about, in columns.
*/
@(private = "file")
memory_report :: proc(ui: ^UI, report: string) {
	ctx := &ui.ctx
	rest := report
	for line in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(line, "# ") {
			mu.layout_row(ctx, {-1})
			mu.label(ctx, "")
			mu.label(ctx, line[2:])
			continue
		}
		amount, _, after := strings.partition(line, "\t")
		detail, _, about := strings.partition(after, "\t")
		mu.layout_row(ctx, {80, 240, -1})
		mu.draw_control_text(ctx, amount, mu.layout_next(ctx), .TEXT, {.ALIGN_RIGHT})
		with_text_color(ctx, theme.dim, detail, label_proc)
		mu.label(ctx, about)
	}
}
