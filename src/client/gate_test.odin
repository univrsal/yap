#+build !wasi
package client

import "core:testing"
import "core:time"

@(test)
test_gate_hysteresis :: proc(t: ^testing.T) {
	g := Gate {
		enabled  = true,
		open_db  = -40,
		close_db = -50,
	}
	now := time.tick_now()
	step :: proc(now: ^time.Tick, ms: int) -> time.Tick {
		now^ = time.tick_add(now^, time.Duration(ms) * time.Millisecond)
		return now^
	}

	testing.expect(t, !gate_update(&g, -60, step(&now, 20)))  // quiet: closed
	testing.expect(t, !gate_update(&g, -45, step(&now, 20)))  // between: stays closed
	testing.expect(t, gate_update(&g, -35, step(&now, 20)))   // loud: opens
	testing.expect(t, gate_update(&g, -45, step(&now, 20)))   // between: stays open
	testing.expect(t, gate_update(&g, -49, step(&now, 20)))   // just above close: open
	// Below close: stays open through the hangover, then closes.
	testing.expect(t, gate_update(&g, -70, step(&now, 20)))
	testing.expect(t, gate_update(&g, -70, step(&now, 200)))
	testing.expect(t, !gate_update(&g, -70, step(&now, 200)))
	testing.expect(t, !gate_update(&g, -45, step(&now, 20)))  // between again: stays closed

	// Disabled: everything is sent, but the state is still tracked for the meter.
	g.enabled = false
	testing.expect(t, gate_update(&g, -70, step(&now, 20)))
	testing.expect(t, !g.open)
}

@(test)
test_level_dbfs :: proc(t: ^testing.T) {
	full: [FRAME_SAMPLES]f32
	for &s in full {
		s = 1
	}
	testing.expect_value(t, level_dbfs(full[:]), 0)

	quiet: [FRAME_SAMPLES]f32
	for &s in quiet {
		s = 0.01 // -40 dBFS
	}
	testing.expect(t, abs(level_dbfs(quiet[:]) + 40) < 0.01)

	silent: [FRAME_SAMPLES]f32
	testing.expect_value(t, level_dbfs(silent[:]), MIN_LEVEL_DB)
}
