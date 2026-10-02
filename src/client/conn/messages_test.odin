#+build !wasi
package conn

import "core:fmt"
import "core:strings"
import "core:testing"

import "common:proto"

// page is messages `from` to `to`, as we'd keep them (owned).
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

	// The first page: the newest, with older ones to come.
	cache_replace(&cache, page(951, 1000), proto.MORE_BEFORE)
	testing.expect(t, cache.have_newest && !cache.have_oldest)
	first, last := ids(&cache)
	testing.expect(t, first == 951 && last == 1000)

	// New ones go on the end; one already there doesn't.
	testing.expect(t, cache_new(&cache, page(1001, 1001)[0]))
	testing.expect(t, cache_new(&cache, page(1001, 1001)[0]))
	testing.expect_value(t, len(cache.messages), 51)

	// Older pages go in front, overlapping or not.
	cache_prepend(&cache, page(901, 955), proto.MORE_BEFORE)
	first, last = ids(&cache)
	testing.expect(t, first == 901 && last == 1001)
	testing.expect_value(t, len(cache.messages), 101)
	consecutive(t, &cache)

	// Scrolled back far enough, the newest go, and new ones aren't taken.
	for from := 851; from > 0; from -= 50 {
		cache_prepend(&cache, page(max(from, 1), from + 49), 0 if from <= 1 else proto.MORE_BEFORE)
	}
	testing.expect_value(t, len(cache.messages), MAX_CACHE_MESSAGES)
	testing.expect(t, cache.have_oldest && !cache.have_newest)
	first, last = ids(&cache)
	testing.expect(t, first == 1 && last == MAX_CACHE_MESSAGES)
	testing.expect(t, !cache_new(&cache, page(1002, 1002)[0]))
	consecutive(t, &cache)

	// Scrolled forward again, the oldest go.
	cache_append(&cache, page(1001, 1002), 0)
	testing.expect(t, cache.have_newest && !cache.have_oldest)
	first, last = ids(&cache)
	testing.expect(t, first == 3 && last == 1002)
	testing.expect_value(t, len(cache.messages), MAX_CACHE_MESSAGES)

	// A jump replaces the lot.
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
	c: Voice_Client
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

	// A new one is added, not the lot copied again.
	cache_new(cache, page(101, 101)[0])
	publish_timeline(&c, conv)
	testing.expect_value(t, len(tl.messages), 51)
	testing.expect_value(t, tl.appended, appended + 1)
	testing.expect_value(t, tl.messages[50].text, "message 101")

	// Older ones go in front, and don't count as new.
	appended = tl.appended
	cache_prepend(cache, page(1, 50), 0)
	publish_timeline(&c, conv)
	testing.expect_value(t, len(tl.messages), 101)
	testing.expect_value(t, tl.messages[0].text, "message 1")
	testing.expect_value(t, tl.appended, appended)
	testing.expect(t, tl.have_oldest && tl.have_newest)

	// A jump elsewhere replaces what's shown.
	cache_replace(cache, page(500, 510), proto.MORE_BEFORE | proto.MORE_AFTER)
	publish_timeline(&c, conv)
	testing.expect_value(t, len(tl.messages), 11)
	testing.expect_value(t, tl.messages[0].id, proto.Msg_Id(500))

	// A fresh connection: the window goes, and so does the UI's copy.
	messages_restart(&c)
	_, still := v.timelines[conv]
	testing.expect(t, !still)
	testing.expect_value(t, len(c.msgs.caches), 0)
}
