#+build wasi
package platform

@(default_calling_convention = "c")
foreign _ {
	// The page's prefers-color-scheme (see web/shell.c).
	yap_prefers_dark :: proc() -> i32 ---
}

// The desktop's own choice is quick to read here, so it needn't be
// asked off the UI thread (which a page hasn't got anyway).
PREFERS_DARK_IS_QUICK :: true

// prefers_dark is whether the browser says the system is dark.
prefers_dark :: proc() -> bool {
	return yap_prefers_dark() != 0
}
