#+build !wasi
package conn

import "core:fmt"
import "core:strings"
import "core:testing"

import "common:proto"

// page returns messages `from` to `to`, as we would keep them (owned).
@(private = "file")
page :: proc(from, to: int) -> []Msg {
	msgs := make([]Msg, to - from + 1, context.temp_allocator)
	for &m, i in msgs {
		id := from + i
		m = {
			id   = proto.Msg_Id(id),
			kind = .Text,
			text = strings.clone(fmt.tprintf("message %d", id)),
		}
	}
	return msgs
}

@(private = "file")
ids :: proc(cache: ^Conv_Cache) -> (first, last: int) {
	if len(cache.messages) == 0 {
		return
	}
	return int(cache.messages[0].id), int(cache.messages[len(cache.messages) - 1].id)
}

@(private = "file")
consecutive :: proc(t: ^testing.T, cache: ^Conv_Cache) {
	for i in 1 ..< len(cache.messages) {
		testing.expect(t, cache.messages[i].id > cache.messages[i - 1].id)
	}
}

@(test)
test_cache_pages :: proc(t: ^testing.T) {
	cache: Conv_Cache
	defer cache_destroy(&cache)

	// The first page contains the newest messages, and older pages follow.
	cache_replace(&cache, page(951, 1000), proto.MORE_BEFORE)
	testing.expect(t, cache.have_newest && !cache.have_oldest)
	first, last := ids(&cache)
	testing.expect(t, first == 951 && last == 1000)

	// New messages are appended, but a message that is already there is not added again.
	testing.expect(t, cache_new(&cache, page(1001, 1001)[0]))
	testing.expect(t, cache_new(&cache, page(1001, 1001)[0]))
	testing.expect_value(t, len(cache.messages), 51)

	// Older pages are added in front, whether or not they overlap.
	cache_prepend(&cache, page(901, 955), proto.MORE_BEFORE)
	first, last = ids(&cache)
	testing.expect(t, first == 901 && last == 1001)
	testing.expect_value(t, len(cache.messages), 101)
	consecutive(t, &cache)

	// When scrolled back far enough, the newest messages are dropped and new ones
	// are not taken.
	for from := 851; from > 0; from -= 50 {
		cache_prepend(&cache, page(max(from, 1), from + 49), 0 if from <= 1 else proto.MORE_BEFORE)
	}
	testing.expect_value(t, len(cache.messages), MAX_CACHE_MESSAGES)
	testing.expect(t, cache.have_oldest && !cache.have_newest)
	first, last = ids(&cache)
	testing.expect(t, first == 1 && last == MAX_CACHE_MESSAGES)
	testing.expect(t, !cache_new(&cache, page(1002, 1002)[0]))
	consecutive(t, &cache)

	// When scrolled forward again, the oldest messages are dropped.
	cache_append(&cache, page(1001, 1002), 0)
	testing.expect(t, cache.have_newest && !cache.have_oldest)
	first, last = ids(&cache)
	testing.expect(t, first == 3 && last == 1002)
	testing.expect_value(t, len(cache.messages), MAX_CACHE_MESSAGES)

	// A jump replaces all messages.
	cache_replace(&cache, page(400, 419), proto.MORE_BEFORE | proto.MORE_AFTER)
	testing.expect(t, !cache.have_newest && !cache.have_oldest)
	testing.expect_value(t, len(cache.messages), 20)
	testing.expect(t, !cache_new(&cache, page(1003, 1003)[0]))
	cache_append(&cache, page(420, 439), proto.MORE_AFTER)
	testing.expect_value(t, len(cache.messages), 40)
	consecutive(t, &cache)
}

@(test)
test_timeline_published :: proc(t: ^testing.T) {
	v: View
	defer view_destroy(&v)
	c: Server_Conn
	c.view = &v
	defer messages_destroy(&c)
	conv := Timeline_Key{3, 0}
	cache := new(Conv_Cache)
	c.msgs.caches[conv] = cache

	cache_replace(cache, page(51, 100), proto.MORE_BEFORE)
	publish_timeline(&c, conv)
	tl := &v.timelines[conv]
	testing.expect_value(t, len(tl.messages), 50)
	testing.expect_value(t, tl.messages[0].text, "message 51")
	appended := tl.appended

	// A new message is added without copying all the others again.
	cache_new(cache, page(101, 101)[0])
	publish_timeline(&c, conv)
	testing.expect_value(t, len(tl.messages), 51)
	testing.expect_value(t, tl.appended, appended + 1)
	testing.expect_value(t, tl.messages[50].text, "message 101")

	// Older messages are added in front and don't count as new.
	appended = tl.appended
	cache_prepend(cache, page(1, 50), 0)
	publish_timeline(&c, conv)
	testing.expect_value(t, len(tl.messages), 101)
	testing.expect_value(t, tl.messages[0].text, "message 1")
	testing.expect_value(t, tl.appended, appended)
	testing.expect(t, tl.have_oldest && tl.have_newest)

	// A jump to another place replaces what is shown.
	cache_replace(cache, page(500, 510), proto.MORE_BEFORE | proto.MORE_AFTER)
	publish_timeline(&c, conv)
	testing.expect_value(t, len(tl.messages), 11)
	testing.expect_value(t, tl.messages[0].id, proto.Msg_Id(500))

	// A fresh connection discards the window, and the UI's copy too.
	messages_restart(&c)
	_, still := v.timelines[conv]
	testing.expect(t, !still)
	testing.expect_value(t, len(c.msgs.caches), 0)
}
