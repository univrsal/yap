package server

import "core:log"

/*
libcurl, for the server's email (email.odin): the few of its procedures
that takes, in a table.

On Linux and macOS it's loaded when email is configured, from the
system's libcurl (curl_load_system in curl_system.odin), so a server
without one runs without email rather than not at all. Windows has no
system libcurl; there the one in Odin's vendor directory is linked in
(curl_windows.odin), a static library, so there's nothing to install.

-define:YAP_EMAIL=false builds a server without email: curl_load says
so and nothing is loaded.
*/

EMAIL_BUILT :: #config(YAP_EMAIL, true)

Curl_Handle :: distinct rawptr
Curl_Slist :: distinct rawptr
// What curl's procedures return: 0 is CURLE_OK.
Curl_Code :: i32

// The options email.odin sets (curl.h's CURLOPT_*).
Curl_Option :: enum i32 {
	Timeout         = 13,
	Verbose         = 41,
	No_Body         = 44,
	Upload          = 46,
	Connect_Timeout = 78,
	No_Signal       = 99,
	Use_Ssl         = 119,
	Write_Data      = 10001,
	Url             = 10002,
	Read_Data       = 10009,
	Error_Buffer    = 10010,
	Custom_Request  = 10036,
	Username        = 10173,
	Password        = 10174,
	Mail_From       = 10186,
	Mail_Rcpt       = 10187,
	Write_Function  = 20011,
	Read_Function   = 20012,
}

// CURLOPT_USE_SSL's values.
CURL_USESSL_NONE :: 0
CURL_USESSL_TRY :: 1
CURL_USESSL_ALL :: 3
// curl_global_init's CURL_GLOBAL_DEFAULT.
CURL_GLOBAL_DEFAULT :: 3
// How big CURLOPT_ERRORBUFFER's buffer has to be.
CURL_ERROR_SIZE :: 256

// curl's write and read callbacks: `size * count` bytes at `data`.
Curl_Io :: #type proc "c" (data: [^]u8, size, count: uint, user: rawptr) -> uint

Curl :: struct {
	loaded:         bool,
	version:        proc "c" () -> cstring,
	global_init:    proc "c" (flags: i64) -> Curl_Code,
	easy_init:      proc "c" () -> Curl_Handle,
	easy_cleanup:   proc "c" (h: Curl_Handle),
	easy_reset:     proc "c" (h: Curl_Handle),
	easy_setopt:    proc "c" (
		h: Curl_Handle,
		option: Curl_Option,
		#c_vararg args: ..any,
	) -> Curl_Code,
	easy_perform:   proc "c" (h: Curl_Handle) -> Curl_Code,
	easy_strerror:  proc "c" (code: Curl_Code) -> cstring,
	slist_append:   proc "c" (list: Curl_Slist, text: cstring) -> Curl_Slist,
	slist_free_all: proc "c" (list: Curl_Slist),
}

/*
curl_load fills in the table and initializes libcurl, once; it's to be
called before any thread uses it. False, with the reason logged, if
there's no libcurl to be had.
*/
curl_load :: proc(c: ^Curl) -> bool {
	if c.loaded {
		return true
	}
	when !EMAIL_BUILT {
		log.warn("this server was built without email (YAP_EMAIL=false)")
		return false
	} else {
		curl_load_system(c) or_return
		if code := c.global_init(CURL_GLOBAL_DEFAULT); code != 0 {
			log.errorf("libcurl could not start: %s", c.easy_strerror(code))
			return false
		}
		c.loaded = true
		log.infof("email through %s", c.version())
		return true
	}
}
