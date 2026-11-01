package core

Extra_Key :: enum {
	Up,
	Down,
	Tab,
	Back_Tab, // Shift+Tab
	Next_Area, // F6: the keyboard focus to the next area (ui/nav.odin)
	Prev_Area, // Shift+F6
	Escape,
	// Space, which presses the control with the keyboard focus (see ui/nav.odin).
	// It still types a space in a text box.
	Activate,
	// Ctrl+Space or Ctrl+K (Cmd+K on macOS): the command palette.
	Palette,
	Newline, // Shift+Enter, or Enter on a phone's keyboard: a new line in a text area
	// Markdown shortcuts in a composer (see composer_keys): Ctrl+B, Ctrl+I, Ctrl+U,
	// Ctrl+Shift+X, Ctrl+E.
	Bold,
	Italic,
	Underline,
	Strike,
	Code,
	// Ctrl+Z, and Ctrl+Y or Ctrl+Shift+Z: undo and redo in a composer
	// (see text/history.odin).
	Undo,
	Redo,
}
