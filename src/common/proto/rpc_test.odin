#+build !wasi
package proto

import "core:slice"
import "core:testing"

@(test)
test_rpc_messages :: proc(t: ^testing.T) {
	body := [3]u8{9, 8, 7}
	req := encode_request(42, .Server_Info, body[:])
	kind, ok := app_kind(req)
	testing.expect(t, ok && kind == .Request)
	id, op, got := decode_request(req)
	testing.expect_value(t, id, 42)
	testing.expect_value(t, op, Request_Op.Server_Info)
	testing.expect(t, slice.equal(got, body[:]))

	resp := encode_response(42, .Denied, nil)
	kind, ok = app_kind(resp)
	testing.expect(t, ok && kind == .Response)
	rid, status, rbody := decode_response(resp)
	testing.expect_value(t, rid, 42)
	testing.expect_value(t, status, Status.Denied)
	testing.expect_value(t, len(rbody), 0)

	ev := encode_event(Event_Op(0x1234), body[:])
	kind, ok = app_kind(ev)
	testing.expect(t, ok && kind == .Event)
	eop, ebody := decode_event(ev)
	testing.expect_value(t, eop, Event_Op(0x1234))
	testing.expect(t, slice.equal(ebody, body[:]))

	// Too short to be what they say, or nothing we know.
	_, ok = app_kind(req[:REQUEST_HEADER_SIZE - 1])
	testing.expect(t, !ok)
	_, ok = app_kind([]u8{77, 0, 0, 0, 0, 0, 0})
	testing.expect(t, !ok)
	_, ok = app_kind(nil)
	testing.expect(t, !ok)

	// A body as long as a stream message can carry, and one longer.
	most := make([]u8, MAX_BODY_SIZE + 1, context.temp_allocator)
	testing.expect_value(
		t,
		len(encode_request(1, .Server_Info, most[:MAX_BODY_SIZE])),
		STREAM_MAX_MESSAGE,
	)
	testing.expect(t, encode_request(1, .Server_Info, most) == nil)
}

@(test)
test_server_info :: proc(t: ^testing.T) {
	buf: [SERVER_INFO_MAX_SIZE]u8
	body, ok := encode_server_info(buf[:], {name = "The Shed", version = "1.2.3"})
	testing.expect(t, ok)
	info: Server_Info
	info, ok = decode_server_info(body)
	testing.expect(t, ok)
	testing.expect_value(t, info.name, "The Shed")
	testing.expect_value(t, info.version, "1.2.3")

	// Fields a newer server added at the end are ignored.
	longer := make([]u8, len(body) + 2, context.temp_allocator)
	copy(longer, body)
	info, ok = decode_server_info(longer)
	testing.expect(t, ok)
	testing.expect_value(t, info.name, "The Shed")

	_, ok = decode_server_info(body[:len(body) - 1])
	testing.expect(t, !ok)
	_, ok = decode_server_info(nil)
	testing.expect(t, !ok)

	long_name := make([]u8, MAX_SERVER_NAME + 1, context.temp_allocator)
	_, ok = encode_server_info(buf[:], {name = string(long_name)})
	testing.expect(t, !ok)
}

@(test)
test_server_info_description_and_icon :: proc(t: ^testing.T) {
	buf: [SERVER_INFO_MAX_SIZE]u8
	body, ok := encode_server_info(
		buf[:],
		{name = "The Shed", version = "1.2.3", description = "For the band.", icon = 42},
	)
	testing.expect(t, ok)
	info: Server_Info
	info, ok = decode_server_info(body)
	testing.expect(t, ok)
	testing.expect_value(t, info.description, "For the band.")
	testing.expect_value(t, info.icon, Blob_Id(42))

	// An older server ends at the email address: no description, no icon.
	old := body[:len(body) - 2 - len("For the band.") - 8]
	info, ok = decode_server_info(old)
	testing.expect(t, ok)
	testing.expect_value(t, info.name, "The Shed")
	testing.expect_value(t, info.description, "")
	testing.expect_value(t, info.icon, Blob_Id(0))

	long_text := make([]u8, MAX_SERVER_DESCRIPTION + 1, context.temp_allocator)
	_, ok = encode_server_info(buf[:], {description = string(long_text)})
	testing.expect(t, !ok)
}

@(test)
test_server_info_set :: proc(t: ^testing.T) {
	buf: [SERVER_INFO_SET_MAX_SIZE]u8
	body, ok := encode_server_info_set(
		buf[:],
		{name = "The Shed", description = "For the band.", icon = 7},
	)
	testing.expect(t, ok)
	set: Server_Info_Set
	set, ok = decode_server_info_set(body)
	testing.expect(t, ok)
	testing.expect_value(t, set.name, "The Shed")
	testing.expect_value(t, set.description, "For the band.")
	testing.expect_value(t, set.icon, Blob_Id(7))

	_, ok = decode_server_info_set(body[:len(body) - 1])
	testing.expect(t, !ok)
	long_text := make([]u8, MAX_SERVER_DESCRIPTION + 1, context.temp_allocator)
	_, ok = encode_server_info_set(buf[:], {description = string(long_text)})
	testing.expect(t, !ok)
}
