package core

import mu "vendor:microui"

Nav_Item :: struct {
	id:       mu.Id,
	rect:     mu.Rect,
	root:     ^mu.Container, // the root container it is drawn in (nil outside any)
	cnt:      ^mu.Container, // the container that scrolls it (a panel or its root)
	text_len: int, // a text box's text length, where the cursor goes; -1 for others
	// A row of a list: the first row's id, shared by the rows drawn right
	// after it in the same container; 0 for a control on its own. Tab stops
	// at a list once, at its `current` row (the selected one) or its first,
	// and Up and Down move in it.
	group:    mu.Id,
	current:  bool,
}

Nav :: struct {
	focus:     mu.Id,
	visible:   bool,
	items:     [dynamic]Nav_Item, // this frame's controls, in draw order
	// Enter or Space was pressed on this control in the last frame: it acts
	// as if clicked in this one.
	activate:  mu.Id,
	// The frame in which a control was last pressed from the keyboard, and
	// the root containers that had controls in the last frame: a window or
	// popup that it opens gets the focus.
	pressed:   mu.Frame_Index,
	roots:     [dynamic]^mu.Container,
	// A popup on top: Tab, Up and Down only move among the controls in it.
	// Set in every frame it is drawn in (nav_trap).
	trap:      ^mu.Container,
	// What gets the focus back once the focused control is gone: what opened
	// the window or popup that has it.
	return_to: mu.Id,
}
