#+build !wasi
package proto

import "core:crypto/ecdh"
import "core:testing"
import "core:time"

@(test)
test_link_step :: proc(t: ^testing.T) {
	key: ecdh.Private_Key
	testing.expect(t, ecdh.private_key_generate(&key, .X25519))
	l: Initiator_Link
	t0 := time.tick_now()
	later :: proc(t0: time.Tick, d: time.Duration) -> time.Tick {
		return time.tick_add(t0, d)
	}

	// No session: a handshake starts, unless the link is holding.
	s := link_step(&l, &key, t0, hold = true)
	testing.expect(t, s.packet == nil && !s.started)
	s = link_step(&l, &key, t0)
	testing.expect(t, s.started && packet_type(s.packet) == .Handshake_Init)

	// Nothing to do while waiting, then the same packet goes again.
	s = link_step(&l, &key, later(t0, HANDSHAKE_RETRY / 2))
	testing.expect(t, s.packet == nil)
	s = link_step(&l, &key, later(t0, HANDSHAKE_RETRY))
	testing.expect(t, s.packet != nil && !s.started)
	testing.expect(t, packet_type(s.packet) == .Handshake_Init)

	// A handshake that takes too long is given up, and none starts in the
	// same step.
	s = link_step(&l, &key, later(t0, HANDSHAKE_TIMEOUT + time.Second))
	testing.expect(t, s.stalled && s.packet == nil)
	testing.expect_value(t, l.handshake.state, Initiator_State.Idle)

	// A working session is left alone until it is due for rekeying, or the
	// server has been quiet.
	l.current.created, l.has_current = t0, true
	l.last_recv = t0
	s = link_step(&l, &key, later(t0, SERVER_SILENT / 2))
	testing.expect(t, s.packet == nil)
	s = link_step(&l, &key, later(t0, SERVER_SILENT + time.Second))
	testing.expect(t, s.started && s.silent)
	link_abandon(&l)
	l.last_recv = later(t0, REKEY_AFTER)
	s = link_step(&l, &key, later(t0, REKEY_AFTER + time.Second))
	testing.expect(t, s.started && !s.silent)
	link_abandon(&l)
	s = link_step(&l, &key, later(t0, SERVER_SILENT / 2), restart = true)
	testing.expect(t, s.started)

	// A session too old to be used is dropped.
	link_abandon(&l)
	l.last_recv = later(t0, REJECT_AFTER)
	s = link_step(&l, &key, later(t0, REJECT_AFTER + time.Second))
	testing.expect(t, s.expired && !l.has_current)
}
