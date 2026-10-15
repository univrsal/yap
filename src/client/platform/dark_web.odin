#+build wasi
package platform

@(default_calling_convention = "c")
foreign _ {
	// The page's prefers-color-scheme (see web/shell.c).
	yap_prefers_dark :: proc() -> i32 ---
}

// The system's preference is quick to read here, so it doesn't need to be
// queried off the UI thread (which a page doesn't have anyway).
PREFERS_DARK_IS_QUICK :: true

// prefers_dark reports whether the browser says the system is in dark mode.
prefers_dark :: proc() -> bool {
	return yap_prefers_dark() != 0
}
