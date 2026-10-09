#+build !wasi
package platform

import "common:."
import "core:fmt"

// agent is what to tell the server this client is, for the account's
// list of devices: "yap 1.2.0 on Linux (amd64)". In the temp allocator.
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
