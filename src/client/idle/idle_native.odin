#+build !wasi
package idle

// On a desktop there is no permission to ask for (see idle_web.odin).
can_ask :: proc() -> bool {
	return false
}

ask :: proc() {}
