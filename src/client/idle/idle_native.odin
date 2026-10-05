#+build !wasi
package idle

// Nothing to ask for on a desktop (see idle_web.odin).
can_ask :: proc() -> bool {
	return false
}

ask :: proc() {}
