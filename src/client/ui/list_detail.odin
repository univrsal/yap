package ui

import "core:fmt"
import "core:strings"
import "widgets"
import mu "vendor:microui"

// List_Detail is a settings category with a list on the left and what is
// picked in it on the right (list_detail).
List_Detail :: struct {
	name:       string, // the picked thing's panel; the list's is "<name> list"
	list_width: i32,
	detail_min: i32, // the least room beside the list before the two take turns
	picked:     bool, // something is picked (or being made)
	title:      string, // what is picked, over it when the two take turns
	back_hint:  string, // the hint of the way back: what the list is
	list:       proc(ui: ^UI),
	detail:     proc(ui: ^UI), // what is picked, or what to show without
	back:       proc(ui: ^UI), // going back to the list
}

// list_detail lays out a List_Detail. In a narrow window the list and what
// is picked take turns, as the settings' categories do: the list, or what is
// picked under its title with a way back to the list.
list_detail :: proc(ui: ^UI, ld: List_Detail) {
	ctx := &ui.ctx
	list_name := strings.concatenate({ld.name, " list"}, context.temp_allocator)
	if widgets.row_room(ctx) < ld.list_width + ld.detail_min {
		if !ld.picked {
			mu.layout_row(ctx, {-1}, -1)
			mu.begin_panel(ctx, list_name)
			ld.list(ui)
			mu.end_panel(ctx)
			return
		}
		mu.layout_row(ctx, {40, -1})
		if .SUBMIT in widgets.icon_button(ui, fmt.tprintf("to %s", list_name), .Back, ld.back_hint) {
			ld.back(ui)
		}
		mu.label(ctx, ld.title)
		mu.layout_row(ctx, {-1}, -1)
		mu.begin_panel(ctx, ld.name)
		ld.detail(ui)
		mu.end_panel(ctx)
		return
	}
	mu.layout_row(ctx, {ld.list_width, -1}, -1)
	mu.begin_panel(ctx, list_name)
	ld.list(ui)
	mu.end_panel(ctx)
	mu.begin_panel(ctx, ld.name)
	ld.detail(ui)
	mu.end_panel(ctx)
}
