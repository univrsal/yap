#+build !wasi
package conn

import "core:testing"

import "common:proto"

// Tests of the server's custom emoji (emoji.odin) and of how typed text is
// turned into what is stored.

@(private = "file")
sheet_body :: proc(sheet: proto.Emoji_Sheet) -> []u8 {
	out := make([]u8, proto.emoji_sheet_max_size(len(sheet.names), len(sheet.animated)), context.temp_allocator)
	return proto.encode_emoji_sheet(out, sheet)
}

@(test)
test_emoji_sheet_event :: proc(t: ^testing.T) {
	tc: Test_Conn
	tc_open(&tc)
	v := tc_view(&tc)
	defer tc_close(&tc)
	defer emoji_destroy(&tc.c)
	defer blobs_destroy(&tc.c)
	c := &tc.c

	tc_event(
		&tc,
		.Emoji_Sheet,
		sheet_body(
			{
				blob = 900,
				size = 5000,
				cell = 32,
				names = {"party", "wave", "zzz"},
				animated = {{index = 2, blob = 901, size = 700}},
			},
		),
	)
	testing.expect_value(t, c.emoji.blob, proto.Blob_Id(900))
	testing.expect_value(t, c.emoji.cell, 32)
	testing.expect_value(t, len(c.emoji.names), 3)
	testing.expect_value(t, c.emoji.names[1], "wave")
	testing.expect_value(t, len(c.emoji.animated), 1)
	testing.expect_value(t, c.emoji.animated[0].blob, proto.Blob_Id(901))

	// The sheet and each animated emoji's frames are fetched, and kept whatever
	// else is cached.
	sheet := c.blobs.cache[900] or_else nil
	testing.expect(t, sheet != nil && sheet.keep)
	if sheet != nil {
		testing.expect_value(t, sheet.image.size, u32(5000))
	}
	anim := c.blobs.cache[901] or_else nil
	testing.expect(t, anim != nil && anim.keep)

	// The UI sees them too, as copies of its own.
	testing.expect_value(t, v.emoji.blob, proto.Blob_Id(900))
	testing.expect_value(t, v.emoji.cell, 32)
	testing.expect_value(t, len(v.emoji.names), 3)
	testing.expect_value(t, len(v.emoji.animated), 1)
	testing.expect_value(t, v.emoji.revision, 1)
	testing.expect(t, raw_data(v.emoji.names[0]) != raw_data(c.emoji.names[0]))
}

@(test)
test_emoji_sheet_replaces_the_old_one :: proc(t: ^testing.T) {
	tc: Test_Conn
	tc_open(&tc)
	v := tc_view(&tc)
	defer tc_close(&tc)
	defer emoji_destroy(&tc.c)
	defer blobs_destroy(&tc.c)
	c := &tc.c

	tc_event(&tc, .Emoji_Sheet, sheet_body({blob = 900, size = 100, cell = 32, names = {"a", "b"}}))
	tc_event(&tc, .Emoji_Sheet, sheet_body({blob = 910, size = 100, cell = 24, names = {"c"}}))
	testing.expect_value(t, c.emoji.blob, proto.Blob_Id(910))
	testing.expect_value(t, c.emoji.cell, 24)
	testing.expect_value(t, len(c.emoji.names), 1)
	testing.expect_value(t, len(c.emoji.animated), 0)
	testing.expect_value(t, len(v.emoji.names), 1)
	testing.expect_value(t, v.emoji.revision, 2)

	// A server without emoji of its own says so: nothing is fetched for it.
	tc_event(&tc, .Emoji_Sheet, sheet_body({blob = 0}))
	testing.expect_value(t, len(c.emoji.names), 0)
	testing.expect_value(t, c.emoji.blob, proto.Blob_Id(0))
	_, fetched := c.blobs.cache[0]
	testing.expect(t, !fetched)
	testing.expect_value(t, v.emoji.blob, proto.Blob_Id(0))
	testing.expect_value(t, v.emoji.revision, 3)
}

@(test)
test_emoji_events_that_are_not_for_it :: proc(t: ^testing.T) {
	tc: Test_Conn
	tc_open(&tc)
	v := tc_view(&tc)
	defer tc_close(&tc)
	defer emoji_destroy(&tc.c)
	defer blobs_destroy(&tc.c)
	c := &tc.c

	testing.expect(t, !emoji_event(c, .Sync_End, nil))
	// A sheet that can't be read is still its event, and changes nothing.
	tc_event(&tc, .Emoji_Sheet, sheet_body({blob = 900, size = 100, cell = 32, names = {"a"}}))
	testing.expect(t, emoji_event(c, .Emoji_Sheet, []u8{1, 2, 3}))
	testing.expect_value(t, len(c.emoji.names), 1)
	testing.expect_value(t, v.emoji.revision, 1)
}

@(test)
test_typed_text_is_stored_as_tokens :: proc(t: ^testing.T) {
	tc: Test_Conn
	tc_open(&tc)
	defer tc_close(&tc)
	defer emoji_destroy(&tc.c)
	defer blobs_destroy(&tc.c)
	c := &tc.c
	tc_account(&tc, 2, "alice", "Alice")
	tc_event(&tc, .Emoji_Sheet, sheet_body({blob = 900, size = 100, cell = 32, names = {"party"}}))

	// Mentions become tokens, shortcodes of Unicode emoji become the character,
	// the server's own emoji stay as they were typed.
	testing.expect_value(t, typed_text(c, "hello"), "hello")
	testing.expect_value(t, typed_text(c, "@alice hi"), "<@2> hi")
	testing.expect_value(t, typed_text(c, "well done :tada:"), "well done 🎉")
	testing.expect_value(t, typed_text(c, "party :party: time"), "party :party: time")
	testing.expect_value(t, typed_text(c, "@alice :tada: :party: :nonsense:"), "<@2> 🎉 :party: :nonsense:")
	// Not a name that exists, not a shortcode.
	testing.expect_value(t, typed_text(c, "@nobody and a:b"), "@nobody and a:b")
	testing.expect_value(t, typed_text(c, ""), "")
}

@(test)
test_custom_emoji_wins_over_unicode :: proc(t: ^testing.T) {
	tc: Test_Conn
	tc_open(&tc)
	defer tc_close(&tc)
	defer emoji_destroy(&tc.c)
	defer blobs_destroy(&tc.c)
	c := &tc.c
	// A server emoji with the name of a Unicode one is used instead of it.
	testing.expect_value(t, typed_text(c, ":tada:"), "🎉")
	tc_event(&tc, .Emoji_Sheet, sheet_body({blob = 900, size = 100, cell = 32, names = {"tada"}}))
	testing.expect_value(t, typed_text(c, ":tada:"), ":tada:")
	// ... until it is gone.
	tc_event(&tc, .Emoji_Sheet, sheet_body({blob = 0}))
	testing.expect_value(t, typed_text(c, ":tada:"), "🎉")
}
