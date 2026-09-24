package common

import "core:math/rand"

// Testing aid: build with -define:YAP_LOSS_PERCENT=30 to drop that share
// of received packets.
LOSS_PERCENT :: #config(YAP_LOSS_PERCENT, 0)
_ :: rand // only used when LOSS_PERCENT > 0

simulate_loss :: proc() -> bool {
	when LOSS_PERCENT > 0 {
		return rand.int_max(100) < LOSS_PERCENT
	} else {
		return false
	}
}
