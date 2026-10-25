package gateway

import "core:encoding/json"

import "lib:http"
import "lib:lite"
import "common:proto"

// The endpoints (docs/bot-api, "Endpoints") live under /api/v1/. Each has a
// `run`, which runs on the gateway thread once its connection is ready, and
// possibly a `prepare`, which runs on the HTTP thread (serve.odin). The first
// route that matches a request is used, so a fixed segment must come before a
// {} in the same position. The read endpoints are in reading.odin.

@(private)
ROUTES := [?]Route {
	{method = "POST", pattern = "login", kind = .Login, prepare = login_prepare},
	{method = "POST", pattern = "logout", kind = .Call, run = logout_run},
	{method = "GET", pattern = "server", kind = .Guest, run = server_run},
	{method = "GET", pattern = "me", kind = .Call, run = me_run},
	{method = "GET", pattern = "accounts", kind = .Call, run = accounts_run},
	{method = "GET", pattern = "accounts/{}", kind = .Call, run = account_run},
	{method = "GET", pattern = "roles", kind = .Call, run = roles_run},
	{method = "GET", pattern = "convs", kind = .Call, run = convs_run},
	{method = "GET", pattern = "convs/browse", kind = .Call, run = browse_run},
	{method = "GET", pattern = "convs/{}", kind = .Call, run = conv_run},
	{method = "GET", pattern = "convs/{}/members", kind = .Call, run = members_run},
	{method = "GET", pattern = "convs/{}/messages", kind = .Call, run = history_run},
	{method = "GET", pattern = "convs/{}/pins", kind = .Call, run = pins_run},
	{method = "GET", pattern = "search", kind = .Call, run = search_run},
	{method = "GET", pattern = "messages/{}/reactions/{}", kind = .Call, run = reactors_run},
	// Writing is in writing.odin.
	{method = "PATCH", pattern = "me", kind = .Call, run = profile_run},
	{method = "PUT", pattern = "me/activity", kind = .Call, run = activity_run},
	{method = "POST", pattern = "dms", kind = .Call, run = dm_run},
	{method = "PUT", pattern = "convs/{}/subscription", kind = .Call, run = subscribe_run},
	{method = "DELETE", pattern = "convs/{}/subscription", kind = .Call, run = unsubscribe_run},
	{method = "POST", pattern = "convs/{}/messages", kind = .Call, run = post_run},
	{method = "POST", pattern = "convs/{}/read", kind = .Call, run = read_run},
	{method = "POST", pattern = "convs/{}/typing", kind = .Call, run = typing_run},
	{method = "PATCH", pattern = "messages/{}", kind = .Call, run = edit_run},
	{method = "DELETE", pattern = "messages/{}", kind = .Call, run = delete_run},
	{method = "PUT", pattern = "messages/{}/pin", kind = .Call, run = pin_run},
	{method = "DELETE", pattern = "messages/{}/pin", kind = .Call, run = unpin_run},
	{method = "PUT", pattern = "messages/{}/reactions/{}", kind = .Call, run = react_run},
	{method = "DELETE", pattern = "messages/{}/reactions/{}", kind = .Call, run = unreact_run},
	{method = "POST", pattern = "messages/{}/forward", kind = .Call, run = forward_run},
	// The file endpoints are in files.odin. Uploads and attachments are
	// streamed and therefore aren't routes (serve.odin).
	{method = "GET", pattern = "blobs/{}", kind = .Call, run = blob_run},
	{method = "PUT", pattern = "me/avatar", kind = .Call, run = avatar_run},
	{method = "DELETE", pattern = "me/avatar", kind = .Call, run = avatar_delete_run},
}

// POST /login {username, password, device} -> {token} creates a new token for
// an ordinary account. From then on the token is a device of that account,
// named `device` ("API" if not given). The gateway generates the key and logs
// in with it like a client does, and the connection then belongs to the
// token.
@(private)
login_prepare :: proc(j: ^Job, req: ^http.Request) -> (r: Reply, done: bool) {
	Login_Body :: struct {
		username: string,
		password: string,
		device:   string,
	}
	b: Login_Body
	if err := json.unmarshal(j.body, &b, allocator = context.temp_allocator); err != nil {
		return error_reply(
				400,
				"invalid",
				"The request body must be JSON like {\"username\": ..., \"password\": ...}.",
			),
			true
	}
	if b.username == "" || b.password == "" {
		return error_reply(400, "invalid", "A username and a password are required."), true
	}
	if len(b.device) > proto.MAX_DEVICE_NAME {
		return error_reply(400, "invalid", "The device name is too long."), true
	}
	j.username, j.password, j.device = b.username, b.password, b.device
	return
}

// POST /logout makes the token stop working, because the device is logged out
// of its account.
@(private)
logout_run :: proc(c: ^Conn, j: ^Job) {
	j.answer = proc(c: ^Conn, j: ^Job, a: lite.Answer) {
		if a.status != .Ok {
			reply(j, status_reply(a.status))
			return
		}
		c.done = true
		reply(j, empty_reply())
	}
	ask(c, j, .Auth_Logout)
}

// GET /server returns what the server reports about itself. No token is
// needed.
@(private)
server_run :: proc(c: ^Conn, j: ^Job) {
	j.answer = proc(c: ^Conn, j: ^Job, a: lite.Answer) {
		if a.status != .Ok {
			reply(j, status_reply(a.status))
			return
		}
		info, ok := proto.decode_server_info(a.body)
		if !ok {
			reply(j, status_reply(.Internal))
			return
		}
		reply(j, json_reply(200, server_json(&info)))
	}
	ask(c, j, .Server_Info)
}

// GET /me returns the token's account and what it is allowed to do.
@(private)
me_run :: proc(c: ^Conn, j: ^Job) {
	reply(j, json_reply(200, me_json(&c.model)))
}
