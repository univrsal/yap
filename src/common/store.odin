package common

// Stores the few things the client has to remember: its private key, the
// servers it has seen before and its settings.
//
// A desktop build keeps them in files under the config directory. A browser
// has no files, so the web build keeps the same named blobs in the page's
// local storage. The names are identical either way, so code using this
// package doesn't need to care which one is in use.
//
// Nothing stored here is big: a key is 64 characters and the settings are a
// few hundred.

// The maximum size of a stored blob, so that a read can use a buffer on
// the stack.
STORE_MAX_SIZE :: 64 * 1024
