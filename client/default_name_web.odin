#+build wasi
package client

// A page has no user name to offer, so the name field starts empty and
// the user fills it in.
default_name :: proc() -> string {
	return ""
}
