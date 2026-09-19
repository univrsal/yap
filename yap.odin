package yap

import "core:fmt"
import "core:os"
import "core:strconv"

USAGE :: `usage:
  yap keygen <key-file>
  yap server <key-file> [port]
  yap client <key-file> <server-public-key> <host:port>`

DEFAULT_PORT :: 7777

main :: proc() {
	args := os.args
	ok := false
	switch {
	case len(args) == 3 && args[1] == "keygen":
		ok = keygen(args[2])
	case (len(args) == 3 || len(args) == 4) && args[1] == "server":
		port := DEFAULT_PORT
		if len(args) == 4 {
			p, p_ok := strconv.parse_int(args[3])
			if !p_ok || p <= 0 || p > 65535 {
				fmt.eprintln("invalid port:", args[3])
				os.exit(2)
			}
			port = p
		}
		ok = run_server(args[2], port)
	case len(args) == 5 && args[1] == "client":
		ok = run_client(args[2], args[3], args[4])
	case:
		fmt.eprintln(USAGE)
		os.exit(2)
	}
	if !ok {
		os.exit(1)
	}
}
