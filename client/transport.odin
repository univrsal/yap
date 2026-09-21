package client

/*
How packets get to the server.

On a desktop that's a UDP socket, which is what the protocol was built
for: datagrams, unordered, lossy, and nothing in the way (see
transport_native.odin).

A browser has no UDP, so a web build sends the same datagrams over a
WebSocket, one packet per message, through a relay that puts them back
on a UDP socket at the other end (see transport_web.odin and server/relay.odin).
Everything above this is unchanged: the packets are the same bytes, the
session is still end-to-end between this client and the server - the
relay carries sealed packets it can't read - and loss and reordering
are still handled, they just happen a good deal less.

Either way the rules here are the same: sending is best-effort, and
receiving never blocks for long. Each side provides the same four
procedures:

	transport_open(t, server_addr) -> bool
	transport_close(t)
	transport_send(t, packet) -> bool
	transport_recv(t, buf) -> (packet, ok)   // ok = false: nothing waiting
*/
