package server

import "core:c"
import "core:log"

// This file contains the libcurl bindings the server needs for email (see
// email.odin) and Web Push (see push.odin). Only the few procedures they use
// are loaded, into a table.
//
// On Linux and macOS, libcurl is loaded from the system when email or push is
// enabled (see curl_load_system in curl_system.odin), so a server without
// libcurl runs without them instead of not running at all. Windows has no
// system libcurl, so the one in Odin's vendor directory is linked in
// statically (see curl_windows.odin) and there is nothing to install.
//
// Building with -define:YAP_EMAIL=false produces a server without libcurl,
// and therefore without email or push. In that case curl_load reports this
// and nothing is loaded.

EMAIL_BUILT :: #config(YAP_EMAIL, true)

Curl_Handle :: distinct rawptr
Curl_Slist :: distinct rawptr
// The result code of curl's procedures, where 0 is CURLE_OK.
Curl_Code :: i32

// The options that email.odin and push.odin set (the CURLOPT_* values from curl.h).
Curl_Option :: enum i32 {
	Timeout              = 13,
	Post_Field_Size      = 60,
	Verbose              = 41,
	No_Body              = 44,
	Upload               = 46,
	Connect_Timeout      = 78,
	No_Signal            = 99,
	Use_Ssl              = 119,
	Write_Data           = 10001,
	Url                  = 10002,
	Read_Data            = 10009,
	Error_Buffer         = 10010,
	Post_Fields          = 10015,
	Http_Header          = 10023,
	Custom_Request       = 10036,
	Open_Socket_Data     = 10164,
	Username             = 10173,
	Password             = 10174,
	Mail_From            = 10186,
	Mail_Rcpt            = 10187,
	Write_Function       = 20011,
	Read_Function        = 20012,
	Open_Socket_Function = 20163,
}

// curl_easy_getinfo's CURLINFO_RESPONSE_CODE: the HTTP status, as a long.
CURLINFO_RESPONSE_CODE :: 0x200002

// What CURLOPT_OPENSOCKETFUNCTION is given: curl.h's struct curl_sockaddr. `addr`
// is the start of a struct sockaddr of `addrlen` bytes, which curl allocates
// room for.
Curl_Sockaddr :: struct {
	family:   c.int,
	socktype: c.int,
	protocol: c.int,
	addrlen:  c.uint,
	addr:     [16]u8,
}

// The address family of IPv4, which is the same on every system. AF_INET6
// differs, so it's defined in curl_system.odin and curl_windows.odin.
AF_INET :: 2

// The values of CURLOPT_USE_SSL.
CURL_USESSL_NONE :: 0
CURL_USESSL_TRY :: 1
CURL_USESSL_ALL :: 3
// The CURL_GLOBAL_DEFAULT flag for curl_global_init.
CURL_GLOBAL_DEFAULT :: 3
// The required size of the buffer for CURLOPT_ERRORBUFFER.
CURL_ERROR_SIZE :: 256

// The signature of curl's write and read callbacks, which handle `size * count`
// bytes at `data`.
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
	easy_getinfo:   proc "c" (h: Curl_Handle, info: i32, #c_vararg args: ..any) -> Curl_Code,
	easy_strerror:  proc "c" (code: Curl_Code) -> cstring,
	slist_append:   proc "c" (list: Curl_Slist, text: cstring) -> Curl_Slist,
	slist_free_all: proc "c" (list: Curl_Slist),
}

// curl_load fills in the table and initializes libcurl. It only does so once, and
// has to be called before any thread uses libcurl. It returns false, with the
// reason logged, if libcurl isn't available. `what` names the feature that
// needs libcurl, for the log.
curl_load :: proc(c: ^Curl, what := "email") -> bool {
	if c.loaded {
		return true
	}
	when !EMAIL_BUILT {
		log.warnf(
			"this server was built without libcurl (YAP_EMAIL=false), so %s is unavailable",
			what,
		)
		return false
	} else {
		curl_load_system(c, what) or_return
		if code := c.global_init(CURL_GLOBAL_DEFAULT); code != 0 {
			log.errorf("libcurl could not be initialized: %s", c.easy_strerror(code))
			return false
		}
		c.loaded = true
		log.infof("%s is using %s", what, c.version())
		return true
	}
}
