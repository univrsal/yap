package conn

/*
What the image cache's two homes have in common: on a desktop a folder
(image_cache_native.odin), in a browser IndexedDB (image_cache_web.odin,
web/images.js). A browser only reads IndexedDB asynchronously, so a
picture is asked for (image_cache_request) and then looked for every
turn of the network loop (image_cache_poll) until it's here; on a
desktop it's here the first time it's looked for.
*/

// A picture asked for from the cache; 0 for none.
Cache_Request :: distinct int

Cache_Poll :: enum {
	Pending,
	Done,
	Failed,
}
