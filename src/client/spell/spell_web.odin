#+build wasi, js
package spell

// On the web the page's own text field is checked by the browser, so there is
// nothing to do here.

Handle :: struct {}

@(private)
backend_available :: proc() -> bool {
	return false
}

@(private)
backend_languages :: proc(dirs: []string, allocator := context.allocator) -> []string {
	return nil
}

@(private)
backend_open :: proc(tag: string, dirs: []string) -> (h: Handle, ok: bool) {
	return {}, false
}

@(private)
backend_close :: proc(h: Handle) {}

@(private)
backend_check :: proc(h: Handle, word: string) -> bool {
	return true
}

@(private)
backend_suggest :: proc(h: Handle, word: string, allocator := context.allocator) -> []string {
	return nil
}
