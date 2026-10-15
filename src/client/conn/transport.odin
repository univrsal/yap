package conn

// How packets get to the server.
//
// On a desktop this is a UDP socket, which is what the protocol was built for:
// datagrams that are unordered and lossy, with nothing in the way (see
// transport_native.odin).
//
// A browser has no UDP, so a web build sends the same datagrams over a
// WebSocket, one packet per message, through a relay that puts them back on a
// UDP socket at the other end (see transport_web.odin and
// src/server/relay.odin). Everything above this layer is unchanged: the packets
// are the same bytes, the session is still end-to-end between this client and
// the server (the relay only carries sealed packets that it cannot read), and
// loss and reordering are still handled, although they happen much less often.
//
// Either way the rules are the same: sending is best-effort, and receiving
// never blocks for long. A client has a transport for each of its links
// (bulk.odin, media.odin), and the receives of the bulk and media links do not
// block at all. Each side provides the same procedures:
//
// 	transport_open(t, server_addr, slot, bulk, media) -> bool
// 	transport_close(t)
// 	transport_send(t, packet) -> bool
// 	transport_recv(t, buf) -> (packet, ok)   // ok = false: nothing waiting
// 	transport_revive(t)                      // reopen a socket that has died
