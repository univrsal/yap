package conn

import log "common:wlog"
import "core:fmt"
import "core:strings"

import "common:proto"

/*
Invite codes (proto/register.odin): making them, listing and revoking
them, and asking which one an account registered with. What comes back
goes straight to the view; headless, it's logged.
*/

// Make an invite code: good for `max_uses` registrations (0: any),
// until `expires` (0: never).
Invite_Create_Command :: struct {
	max_uses: u16,
	expires:  proto.Unix_Ms,
}
// List the invite codes: ours, or with Manage_Accounts everybody's.
Invites_Command :: struct {}
Invite_Revoke_Command :: struct {
	code: string, // owned by the command
}
// Which code an account registered with (Manage_Accounts).
Invite_Of_Command :: struct {
	account: proto.Account_Id,
}

View_Invites :: struct {
	// As of the last time they were asked for, newest first; codes owned.
	list:       [dynamic]proto.Invite,
	count:      int, // bumped each time the list arrives
	// The code just made, to be shown (it's in the list too); owned.
	made:       string,
	made_count: int,
	// Which code accounts registered with, as far as asked.
	of:         map[proto.Account_Id]View_Invite_Of,
}

View_Invite_Of :: struct {
	code:    string, // owned; "" if none
	creator: proto.Account_Id,
}

view_clear_invites :: proc(v: ^View) {
	for inv in v.invites.list {
		delete(inv.code)
	}
	clear(&v.invites.list)
	delete(v.invites.made)
	v.invites.made = ""
	for _, of in v.invites.of {
		delete(of.code)
	}
	clear(&v.invites.of)
}

view_destroy_invites :: proc(v: ^View) {
	view_clear_invites(v)
	delete(v.invites.list)
	delete(v.invites.of)
}

invite_create :: proc(c: ^Voice_Client, cmd: Invite_Create_Command) {
	buf: [proto.INVITE_CREATE_SIZE]u8
	request(
		c,
		.Invite_Create,
		proto.encode_invite_create(&buf, cmd.max_uses, cmd.expires),
		proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
			#partial switch status {
			case .Ok:
			case .Too_Large:
				notify(c, false, "You have as many invite codes as you may: revoke some first.")
				return
			case:
				notify(c, false, status_text(status))
				return
			}
			code, ok := proto.decode_invite_code(body)
			buf: [proto.INVITE_CODE_SIZE]u8
			clean, clean_ok := proto.invite_code_clean(code, &buf)
			if !ok || !clean_ok {
				return
			}
			if v := c.view; v != nil {
				view_write(v)
				delete(v.invites.made)
				v.invites.made = strings.clone(clean)
				v.invites.made_count += 1
			} else {
				log.infof("invite code: %s", clean)
			}
			invites_list(c)
		},
	)
}

invites_list :: proc(c: ^Voice_Client) {
	request(
		c,
		.Invite_List,
		nil,
		proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
			if status != .Ok {
				return
			}
			invites, ok := proto.decode_invites(body)
			if !ok {
				return
			}
			v := c.view
			if v == nil {
				for inv in invites {
					log.infof(
						"invite %s: %d of %s uses%s%s",
						inv.code,
						inv.uses,
						"any" if inv.max_uses == 0 else fmt.tprint(inv.max_uses),
						", expires" if inv.expires != 0 else "",
						", revoked" if inv.revoked else "",
					)
				}
				return
			}
			view_write(v)
			for inv in v.invites.list {
				delete(inv.code)
			}
			clear(&v.invites.list)
			for inv in invites {
				inv := inv
				inv.code = strings.clone(inv.code)
				append(&v.invites.list, inv)
			}
			v.invites.count += 1
		},
	)
}

invite_revoke :: proc(c: ^Voice_Client, code: string) {
	buf: [1 + proto.INVITE_CODE_SIZE]u8
	body := proto.encode_invite_code(&buf, code)
	if body == nil {
		return
	}
	request(
		c,
		.Invite_Revoke,
		body,
		proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
			if status != .Ok {
				notify(c, false, status_text(status))
				return
			}
			invites_list(c)
		},
	)
}

invite_of :: proc(c: ^Voice_Client, account: proto.Account_Id) {
	buf: [4]u8
	request(
		c,
		.Invite_Of,
		proto.encode_account_id(&buf, account),
		proc(c: ^Voice_Client, status: proto.Status, body: []u8, tag: u64) {
			account := proto.Account_Id(tag)
			of: View_Invite_Of
			#partial switch status {
			case .Ok:
				code, creator, ok := proto.decode_invite_of(body)
				if !ok {
					return
				}
				of = {strings.clone(code), creator}
			case .Not_Found:
			case:
				return
			}
			v := c.view
			if v == nil {
				if of.code != "" {
					log.infof("account %d registered with invite %s", account, of.code)
					delete(of.code)
				}
				return
			}
			view_write(v)
			if old, had := v.invites.of[account]; had {
				delete(old.code)
			}
			v.invites.of[account] = of
		},
		u64(account),
	)
}
