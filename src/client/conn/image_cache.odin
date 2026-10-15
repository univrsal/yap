package conn

// This file has what the two image cache implementations have in common. On a
// desktop the cache is a folder (image_cache_native.odin), and in a browser it
// is IndexedDB (image_cache_web.odin, web/images.js). A browser can only read
// IndexedDB asynchronously, so a picture is first requested
// (image_cache_request) and then polled on every turn of the network loop
// (image_cache_poll) until it is available. On a desktop it is available the
// first time it is looked up.

// A picture requested from the cache. 0 means no request.
Cache_Request :: distinct int

Cache_Poll :: enum {
	Pending,
	Done,
	Failed,
}
