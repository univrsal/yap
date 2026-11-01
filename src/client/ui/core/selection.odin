package core

import "client:conn"
import "core:strings"

Select_Panel :: enum {
	None,
	Chat,
	Log,
	// The thread windows' (ui/threads.odin), by slot.
	Thread_1,
	Thread_2,
	Thread_3,
	Thread_4,
}

#assert(int(Select_Panel.Thread_4) - int(Select_Panel.Thread_1) + 1 == conn.MAX_THREADS)

Text_Pos :: struct {
	item:   i64,
	offset: int, // byte offset into the item's text
}

Selection :: struct {
	panel:     Select_Panel, // the panel the selection is in; None for no selection
	anchor:    Text_Pos,
	focus:     Text_Pos,
	dragging:  bool,

	// This frame's state for the panel being drawn (select_begin to
	// select_end).
	drawing:   Select_Panel,
	pressed:   bool, // the button went down over the panel
	hit:       Text_Pos, // the place under the pointer, so far
	found:     bool, // `hit` is set
	over_text: bool, // the pointer is on some text or a text box, so it shows an I-beam cursor
	text:      strings.Builder, // the selected text, for Ctrl+C
	last_item: i64, // the item that text was last added from
}
