package yap

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strconv"

USAGE :: `usage:
  yap keygen <key-file>
  yap server <key-file> [port]
  yap client <key-file> <host:port> [known-servers-file]

Key files are created if they don't exist. The client remembers each
server's key on first connect (default: <config dir>/yap/known_servers)
and refuses to connect if it later changes.`

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
	case (len(args) == 4 || len(args) == 5) && args[1] == "client":
		known_servers := len(args) == 5 ? args[4] : default_known_servers_path()
		if known_servers == "" {
			fmt.eprintln("could not determine config directory; pass a known-servers file")
			os.exit(2)
		}
		ok = run_client(args[2], args[3], known_servers)
	case:
		fmt.eprintln(USAGE)
		os.exit(2)
	}
	if !ok {
		os.exit(1)
	}
}

// Testing aid: build with -define:YAP_LOSS_PERCENT=30 to drop that share
// of received packets on both client and server.
LOSS_PERCENT :: #config(YAP_LOSS_PERCENT, 0)
_ :: rand // only used when LOSS_PERCENT > 0

simulate_loss :: proc() -> bool {
	when LOSS_PERCENT > 0 {
		return rand.int_max(100) < LOSS_PERCENT
	} else {
		return false
	}
}
