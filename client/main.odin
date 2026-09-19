package client

import "core:fmt"
import "core:os"

USAGE :: `usage: yap-client <key-file> <host:port> [known-servers-file]

The key file is created if it doesn't exist. The server's key is
remembered on first connect (default: <config dir>/yap/known_servers)
and the connection is refused if it later changes.`

main :: proc() {
	args := os.args
	if len(args) != 3 && len(args) != 4 {
		fmt.eprintln(USAGE)
		os.exit(2)
	}

	known_servers := len(args) == 4 ? args[3] : default_known_servers_path()
	if known_servers == "" {
		fmt.eprintln("could not determine config directory; pass a known-servers file")
		os.exit(2)
	}

	if !run_client(args[1], args[2], known_servers) {
		os.exit(1)
	}
}
