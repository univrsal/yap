package core

import mu "vendor:microui"

Dropdown_Item :: struct {
	label:  string,
	header: bool, // a heading over the choices after it, not a choice
}

Dropdown_State :: struct {
	open:      mu.Id, // the dropdown whose list is open, 0 for none
	requested: bool, // the list opens in this frame
	// The open dropdown's button, choices and current choice, as of this
	// frame (`frame`). The items are the caller's, in the temp allocator.
	anchor:    mu.Rect,
	items:     []Dropdown_Item,
	current:   int,
	frame:     mu.Frame_Index,
	// What was picked from the list, for the dropdown `picked_id`.
	picked:    int,
	picked_id: mu.Id,
}
