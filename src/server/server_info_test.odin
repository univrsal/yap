package server

import "core:os"
import "core:slice"
import "core:testing"

import "common:proto"

// Tests of what the server says about itself (server_info.odin), on the
// Test_Server of auth_test.odin.

@(private = "file")
info_set :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	set: proto.Server_Info_Set,
) -> proto.Status {
	buf: [proto.SERVER_INFO_SET_MAX_SIZE]u8
	body, ok := proto.encode_server_info_set(buf[:], set)
	testing.expect(t, ok)
	status, _ := ts_ask(t, ts, u, .Server_Info_Set, body)
	return status
}

@(private = "file")
icon_of :: proc(
	t: ^testing.T,
	ts: ^Test_Server,
	u: ^Conn,
	blob: proto.Blob_Id,
) -> (
	proto.Status,
	[]u8,
) {
	buf: [proto.BLOB_GET_SIZE]u8
	return ts_ask(t, ts, u, .Server_Icon, proto.encode_blob_id(&buf, blob))
}

@(test)
test_server_info_set :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "yap-test-*", context.temp_allocator)
	defer os.remove_all(dir)
	path, _ := os.join_path({dir, DB_FILE}, context.temp_allocator)
	blobs, _ := os.join_path({dir, "blobs"}, context.temp_allocator)

	jpeg := test_jpeg(64, 64, 3)
	icon: proto.Blob_Id
	{
		ts: Test_Server
		ts_open(t, &ts, path)
		defer ts_close(&ts)
		s := &ts.s
		testing.expect(t, blob_store_open(&s.blobs, &s.db, blobs))
		defer blob_store_close(&s.blobs)
		server_info_load(s, "From the config")
		defer server_info_destroy(s)
		testing.expect_value(t, s.name, "From the config")

		ts_account(t, &ts, "owner", "a password", {.Owner})
		ts_account(t, &ts, "bob", "a password")
		o := logged_in(t, &ts, "owner")
		b := logged_in(t, &ts, "bob")
		stranger := ts_connect(&ts)

		stored: bool
		icon, stored = blob_put(&s.blobs, .Avatar, jpeg, 64, 64)
		testing.expect(t, stored)

		// The owner's to change, and nobody else's.
		set := proto.Server_Info_Set {
			name        = "  The\tShed ",
			description = "For the band.\n\nRehearsals on Tuesdays.",
			icon        = icon,
		}
		testing.expect_value(t, info_set(t, &ts, b, set), proto.Status.Denied)
		testing.expect_value(t, info_set(t, &ts, stranger, set), proto.Status.Unauthenticated)
		testing.expect_value(t, info_set(t, &ts, o, set), proto.Status.Ok)
		testing.expect_value(t, s.name, "The Shed")
		testing.expect_value(t, s.description, "For the band.\n\nRehearsals on Tuesdays.")
		testing.expect_value(t, s.icon, icon)

		// Everyone logged in is told.
		heard := false
		for e in ts_events(t, &ts, b) {
			if e.op != .Server_Info {
				continue
			}
			info, ok := proto.decode_server_info(e.body)
			testing.expect(t, ok)
			testing.expect_value(t, info.name, "The Shed")
			testing.expect_value(t, info.icon, icon)
			heard = true
		}
		testing.expect(t, heard)

		// Asked before logging in: what it says, and its picture, but no
		// other blob.
		status, body := ts_ask(t, &ts, stranger, .Server_Info)
		testing.expect_value(t, status, proto.Status.Ok)
		info, ok := proto.decode_server_info(body)
		testing.expect(t, ok)
		testing.expect_value(t, info.description, "For the band.\n\nRehearsals on Tuesdays.")
		testing.expect_value(t, info.icon, icon)
		status, body = icon_of(t, &ts, stranger, icon)
		testing.expect_value(t, status, proto.Status.Ok)
		testing.expect(t, slice.equal(body, jpeg))
		other, _ := blob_put(&s.blobs, .Avatar, test_jpeg(32, 32, 5), 32, 32)
		status, _ = icon_of(t, &ts, stranger, other)
		testing.expect_value(t, status, proto.Status.Not_Found)
		status, _ = icon_of(t, &ts, stranger, 0)
		testing.expect_value(t, status, proto.Status.Invalid)

		// Only a small square picture will do.
		big, _ := blob_put(&s.blobs, .Avatar, test_jpeg(200, 200, 6), 200, 200)
		wide, _ := blob_put(&s.blobs, .Avatar, test_jpeg(64, 32, 7), 64, 32)
		file, _ := blob_put(&s.blobs, .File, test_jpeg(48, 48, 8), 48, 48)
		testing.expect_value(t, info_set(t, &ts, o, {icon = big}), proto.Status.Too_Large)
		testing.expect_value(t, info_set(t, &ts, o, {icon = wide}), proto.Status.Invalid)
		testing.expect_value(t, info_set(t, &ts, o, {icon = file}), proto.Status.Invalid)
		testing.expect_value(t, info_set(t, &ts, o, {icon = 999}), proto.Status.Not_Found)
		testing.expect_value(t, s.icon, icon)
	}

	// Kept: the config's name no longer counts.
	{
		ts: Test_Server
		ts_open(t, &ts, path)
		defer ts_close(&ts)
		s := &ts.s
		server_info_load(s, "From the config")
		defer server_info_destroy(s)
		testing.expect_value(t, s.name, "The Shed")
		testing.expect_value(t, s.description, "For the band.\n\nRehearsals on Tuesdays.")
		testing.expect_value(t, s.icon, icon)
	}
}
