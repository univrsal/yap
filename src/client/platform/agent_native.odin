#+build !wasi
package platform

import "common:."
import "core:fmt"

// agent returns the description of this client that is sent to the server for
// the account's list of devices, e.g. "yap 1.2.0 on Linux (amd64)". The string
// is allocated in the temp allocator.
agent :: proc() -> string {
	os_name := "unknown OS"
	when ODIN_OS == .Windows {
		os_name = "Windows"
	} else when ODIN_OS == .Darwin {
		os_name = "macOS"
	} else when ODIN_OS == .Linux {
		os_name = "Linux"
	} else when ODIN_OS == .FreeBSD {
		os_name = "FreeBSD"
	}
	return fmt.tprintf("yap %s on %s (%v)", common.version(), os_name, ODIN_ARCH)
}
