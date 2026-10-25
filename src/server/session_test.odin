#+build !wasi
package server

import "core:testing"
import "core:time"

@(test)
test_session_rewelcome_throttled :: proc(t: ^testing.T) {
	b: Session_Base
	testing.expect(t, session_rewelcome_due(&b))
	testing.expect(t, !session_rewelcome_due(&b))
	b.rewelcomed = time.tick_add(b.rewelcomed, -2 * REWELCOME_EVERY)
	testing.expect(t, session_rewelcome_due(&b))
}

@(test)
test_session_expired :: proc(t: ^testing.T) {
	now := time.tick_now()
	b := Session_Base {
		started   = now,
		last_recv = now,
	}
	testing.expect(t, !session_expired(&b))
	b.started = time.tick_add(now, -10 * time.Second)
	testing.expect(t, session_expired(&b)) // never keyed
	b.keyed = true
	b.created = now
	testing.expect(t, !session_expired(&b))
	b.last_recv = time.tick_add(now, -time.Hour)
	testing.expect(t, session_expired(&b))
}

@(test)
test_session_confirm_once :: proc(t: ^testing.T) {
	b: Session_Base
	testing.expect(t, session_confirm(&b))
	testing.expect(t, !session_confirm(&b))
	other: Session_Base
	other.superseded = true
	testing.expect(t, !session_confirm(&other))
}
