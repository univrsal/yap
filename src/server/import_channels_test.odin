package server

import "core:strings"
import "core:testing"

import "common:proto"
import "mattermost"

// The importer's channels, members and direct conversations
// (import_channels.odin), from the sample export. Its memberships were read
// again with a script that doesn't use this code.

@(private = "file")
members_of :: proc(conv: ^Conv, a: ^Accounts) -> string {
	names := make([dynamic]string, 0, len(conv.members), context.temp_allocator)
	for id in conv.members {
		append(&names, a.by_id[id].username)
	}
	slice_sort_strings(names[:])
	return strings.join(names[:], " ", context.temp_allocator)
}

@(private = "file")
slice_sort_strings :: proc(list: []string) {
	for i in 1 ..< len(list) {
		for j := i; j > 0 && list[j] < list[j - 1]; j -= 1 {
			list[j], list[j - 1] = list[j - 1], list[j]
		}
	}
}

@(private = "file")
admins_of :: proc(conv: ^Conv, a: ^Accounts) -> string {
	names := make([dynamic]string, 0, 4, context.temp_allocator)
	for id in conv_admins(conv) {
		append(&names, a.by_id[id].username)
	}
	slice_sort_strings(names[:])
	return strings.join(names[:], " ", context.temp_allocator)
}

@(test)
test_import_channels :: proc(t: ^testing.T) {
	it: Import_Test
	if !it_open(t, &it, IMPORT_SAMPLE) {
		return
	}
	defer it_close(&it)
	testing.expect(t, import_accounts(&it.im))
	testing.expect(t, import_channels(&it.im))
	db_commit(&it.db)
	c := &it.convs
	a := &it.accounts

	// Six channels, four DMs (one with oneself) and two groups.
	channels, dms, groups := 0, 0, 0
	for _, conv in c.by_id {
		switch conv.kind {
		case .Channel:
			channels += 1
		case .DM:
			dms += 1
		case .Group:
			groups += 1
		}
	}
	testing.expect_value(t, channels, 6)
	testing.expect_value(t, dms, 4)
	testing.expect_value(t, groups, 2)

	// town-square is the home channel that the server made, and everyone is in it.
	home := c.home
	testing.expect_value(t, home.name, "Town Square")
	testing.expect_value(t, home.flags, proto.Conv_Flags{.Home, .Text_Only})
	testing.expect_value(t, it.im.channels[0], home)
	testing.expect_value(t, len(home.members), 11)

	byname :: proc(c: ^Convs, name: string) -> ^Conv {
		return conv_by_name(c, name)
	}
	off := byname(c, "Off-Topic")
	testing.expect(t, off != nil)
	if off != nil {
		testing.expect_value(t, off.flags, proto.Conv_Flags{.Default, .Text_Only})
		testing.expect_value(t, members_of(off, a), "admin alice bob carol dave frank gus")
		testing.expect_value(t, admins_of(off, a), "")
	}
	secret := byname(c, "Secret")
	testing.expect(t, secret != nil)
	if secret != nil {
		testing.expect_value(t, secret.flags, proto.Conv_Flags{.Private, .Text_Only})
		testing.expect_value(t, members_of(secret, a), "admin alice bob")
		testing.expect_value(t, admins_of(secret, a), "admin")
		testing.expect_value(t, secret.topic, "Only a purpose, no header")
	}
	general := byname(c, "General Talk Renamed")
	testing.expect(t, general != nil)
	if general != nil {
		testing.expect_value(t, members_of(general, a), "admin alice bob carol dave gus")
		testing.expect_value(t, admins_of(general, a), "admin bob")
		testing.expect_value(t, general.topic, "Talk about *anything* (really)")
		// carol asked for mentions only there, and nobody else for anything.
		testing.expect_value(
			t,
			general.reads[account_find(a, "carol").id].notify,
			proto.Notify_Level.Mentions,
		)
		testing.expect_value(
			t,
			general.reads[account_find(a, "bob").id].notify,
			proto.Notify_Level.All,
		)
	}
	phoenix := byname(c, "Phoenix")
	testing.expect(t, phoenix != nil)
	if phoenix != nil {
		testing.expect_value(t, members_of(phoenix, a), "admin alice carol")
	}
	// An archived channel is still there, with its members, but not found by name.
	old: ^Conv
	for _, conv in c.by_id {
		if conv.name == "Old Stuff" {
			old = conv
		}
	}
	testing.expect(t, old != nil)
	if old != nil {
		testing.expect_value(t, old.flags, proto.Conv_Flags{.Archived, .Text_Only})
		testing.expect_value(t, members_of(old, a), "admin alice bob carol")
	}

	// Alphabetical, with the archived channel last.
	order := []string{"General Talk Renamed", "Off-Topic", "Phoenix", "Secret", "Old Stuff"}
	for name, i in order {
		for _, conv in c.by_id {
			if conv.name == name {
				testing.expectf(t, conv.position == i + 1, "%s is at %d", name, conv.position)
			}
		}
	}

	// Direct conversations, by who is in them.
	testing.expect_value(t, len(it.im.directs), 6)
	Expected :: struct {
		key:  string,
		kind: proto.Conv_Kind,
	}
	expected := []Expected {
		{"admin,buildbot", .DM},
		{"alice,bob", .DM},
		{"alice,dave", .DM},
		{"alice", .DM},
		{"alice,bob,carol", .Group},
		{"bob,carol,dave,frank", .Group},
	}
	for e in expected {
		conv := it.im.directs[e.key]
		testing.expectf(t, conv != nil && conv.kind == e.kind, "%s", e.key)
	}
	self := it.im.directs["alice"]
	if self != nil {
		testing.expect(t, self.a == self.b && self.a == account_find(a, "alice").id)
	}
	group := it.im.directs["bob,carol,dave,frank"]
	if group != nil {
		testing.expect_value(t, members_of(group, a), "bob carol dave frank")
	}

	// It is in the database too, as the server will load it.
	testing.expect_value(t, it_count(&it, "SELECT count(*) FROM convs"), 12)
	testing.expect_value(t, it_count(&it, "SELECT count(*) FROM members WHERE admin != 0"), 5)
	testing.expect_value(t, it_count(&it, "SELECT count(*) FROM members WHERE notify = 1"), 1)
	testing.expect_value(t, it_count(&it, "SELECT count(*) FROM convs WHERE flags & 4 != 0"), 1) // archived
	loaded: Convs
	testing.expect(t, convs_load(&loaded, &it.db, []string{DEFAULT_CHANNEL_NAME}, a))
	defer convs_destroy(&loaded)
	testing.expect_value(t, len(loaded.by_id), 12)
	testing.expect_value(t, loaded.home.name, "Town Square")
	testing.expect_value(t, len(loaded.groups), 2)
	testing.expect_value(t, len(loaded.dms), 4)
}

@(test)
test_import_channels_undo :: proc(t: ^testing.T) {
	it: Import_Test
	if !it_open(t, &it, IMPORT_SAMPLE) {
		return
	}
	defer it_close(&it)
	testing.expect(t, import_accounts(&it.im))
	testing.expect(t, import_channels(&it.im))
	import_undo(&it.im)
	// What was there before is there again: no accounts, no members, no extra
	// conversations (the home channel is the server's own).
	testing.expect_value(t, it_count(&it, "SELECT count(*) FROM accounts"), 0)
	testing.expect_value(t, it_count(&it, "SELECT count(*) FROM members"), 0)
	testing.expect_value(t, it_count(&it, "SELECT count(*) FROM convs"), 0) // the seed was in the transaction too
}

@(test)
test_import_home_name :: proc(t: ^testing.T) {
	version := `{"type":"version","version":1,"info":{"generator":"mattermost-server","version":"x","created":"2026-01-01T00:00:00Z"}}`
	// No town-square, and a channel that is called what the server's home channel is.
	dir := export_of(
		t,
		version,
		`{"type":"team","team":{"name":"acme","display_name":"Acme","type":"O"}}`,
		`{"type":"channel","channel":{"team":"acme","name":"lobby","display_name":"Lobby","type":"O","scheme":"custom_scheme"}}`,
		`{"type":"user","user":{"username":"root","roles":"system_admin","teams":[{"name":"acme","roles":"team_user","channels":[{"name":"lobby","roles":"channel_user channel_admin","notify_props":{"desktop":"none"}}]}]}}`,
	)
	defer {
		remove_tree(dir)
		delete(dir)
	}
	it: Import_Test
	if !it_open(t, &it, dir) {
		return
	}
	defer it_close(&it)
	testing.expect_value(t, it.scan.issues[.Channel_Scheme].count, 1)
	testing.expect(t, import_accounts(&it.im))
	testing.expect(t, import_channels(&it.im))
	// The server's channel is still the home channel, and gives way.
	testing.expect_value(t, it.convs.home.name, "Lobby (home)")
	lobby := conv_by_name(&it.convs, "Lobby")
	testing.expect(t, lobby != nil && lobby != it.convs.home)
	if lobby != nil {
		root := account_find(&it.accounts, "root")
		testing.expect(t, conv_admin(lobby, root.id))
		testing.expect_value(t, lobby.reads[root.id].notify, proto.Notify_Level.None)
	}
	_ = mattermost.DATA_DIR
}
