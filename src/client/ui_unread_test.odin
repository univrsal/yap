#+build !wasi
package client

import "core:testing"

import "client:conn"
import "client:settings"

// Only channels that notify for everything count towards what is unread in
// the title and the tray: a muted one doesn't, and neither does one that is
// only for mentions (whose mentions are counted on their own).
@(test)
test_unread_total_notify :: proc(t: ^testing.T) {
	s: settings.Settings
	v: conn.View
	defer delete(v.channels)
	append(&v.channels, conn.View_Channel{id = 1, notify = .All, unread = 3})
	append(&v.channels, conn.View_Channel{id = 2, notify = .Mentions, unread = 5, mentions = 1})
	append(&v.channels, conn.View_Channel{id = 3, notify = .None, unread = 7})
	testing.expect_value(t, unread_total(&s, &v), 3)

	v.channels[0].unread = 0
	testing.expect_value(t, unread_total(&s, &v), 0)
}
