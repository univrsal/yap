package server

import "core:fmt"
import "core:os"
import "core:strconv"

USAGE :: `usage: yap-server <key-file> [port]

The key file is created if it doesn't exist. Clients learn the server's
key on first connect, so keep the file: a new key makes every client
refuse to connect until they remove the old one.`

DEFAULT_PORT :: 7777

main :: proc() {
	args := os.args
	if len(args) != 2 && len(args) != 3 {
		fmt.eprintln(USAGE)
		os.exit(2)
	}

	port := DEFAULT_PORT
	if len(args) == 3 {
		p, ok := strconv.parse_int(args[2])
		if !ok || p <= 0 || p > 65535 {
			fmt.eprintln("invalid port:", args[2])
			os.exit(2)
		}
		port = p
	}

	if !run_server(args[1], port) {
		os.exit(1)
	}
}
