package common

/*
Where the client keeps the few things it has to remember: its private
key, the servers it has seen before, its settings.

A desktop keeps them in files under the config directory. A browser has
no files, so a web build keeps the same named blobs in the page's local
storage - the names are the same either way, so everything above this
reads and writes them without caring which it is.

Nothing here is big: a key is 64 characters, settings a few hundred.
*/

// The most any of these is allowed to be, so a read can use a buffer on
// the stack.
STORE_MAX_SIZE :: 64 * 1024
