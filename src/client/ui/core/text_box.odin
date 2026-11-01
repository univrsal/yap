package core

import mu "vendor:microui"

Text_Box :: struct {
	id:        mu.Id,
	rect:      mu.Rect, // as visible: clipped to its container
	multiline: bool, // a text area (ui/widgets/text_area.odin), where Enter starts a line
	// The page's own text field is over it (ui/widgets/field_web.odin), so a tap
	// lands there and brings the keyboard up itself.
	live:      bool,
}
