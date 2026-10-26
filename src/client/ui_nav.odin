package client

// Moving through the UI with the keyboard (docs/design/keyboard.md).

// key_take takes `k` out of this frame's keys and says whether it was there,
// so that whoever uses a key first is the only one to see it.
key_take :: proc(ui: ^UI, k: Extra_Key) -> bool {
	if k not_in ui.keys {
		return false
	}
	ui.keys -= {k}
	return true
}
