#+build windows
package server

import curl "vendor:curl"

// curl_load_system takes libcurl from Odin's vendor directory, which is
// linked in: Windows has no libcurl of its own.
curl_load_system :: proc(c: ^Curl) -> bool {
	c.version = auto_cast curl.version
	c.global_init = auto_cast curl.global_init
	c.easy_init = auto_cast curl.easy_init
	c.easy_cleanup = auto_cast curl.easy_cleanup
	c.easy_reset = auto_cast curl.easy_reset
	c.easy_setopt = auto_cast curl.easy_setopt
	c.easy_perform = auto_cast curl.easy_perform
	c.easy_strerror = auto_cast curl.easy_strerror
	c.slist_append = auto_cast curl.slist_append
	c.slist_free_all = auto_cast curl.slist_free_all
	return true
}
