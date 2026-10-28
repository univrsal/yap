package server

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem/virtual"
import "core:slice"
import "core:strings"

import "common:proto"
import "mattermost"

// The importer's writing of messages (docs/design/mattermost-import.md, 7e):
// pass 2 over the posts, in the order they were written, so that a message's id
// follows its time. Channels and accounts have to be made already.

// import_messages writes every post and reply that the scan found as a message
// (or a system message). It writes in the open transaction and returns false,
// with a message logged, if anything fails.
import_messages :: proc(im: ^Importer) -> bool {
	s := im.scan
	a := virtual.arena_allocator(&im.arena)

	// In time order. Posts of one time keep the order of the file, with a
	// thread's first post before its replies (a reply's time is never before it).
	refs := s.posts[:]
	slice.sort_by(refs, proc(x, y: mattermost.Post_Ref) -> bool {
		if x.time != y.time {
			return x.time < y.time
		}
		if x.offset != y.offset {
			return x.offset < y.offset
		}
		return x.reply < y.reply
	})

	reader: mattermost.Post_Reader
	if err := mattermost.post_reader_open(&reader, s, a); err != "" {
		log.error(err)
		return false
	}
	defer mattermost.post_reader_close(&reader)

	progress := progress_start("importing messages")
	for ref, i in refs {
		progress_update(&progress, i64(i), i64(len(refs)))
		import_post(im, &reader, ref) or_return
	}
	progress.done = i64(len(refs))
	progress_finish(&progress)

	import_limits(im) or_return

	// What the messages add up to: each thread's replies and last reply, and each
	// conversation's last message.
	for _, root in im.roots {
		q := db_query(im.db, .Thread_Recount, i64(root))
		if !db_run(im.db, q) {
			log.error("could not count the replies of a thread")
			return false
		}
	}
	made := len(im.channels) + len(im.direct_list)
	conversations := make([dynamic]^Conv, 0, made, context.temp_allocator)
	append(&conversations, ..im.channels)
	append(&conversations, ..im.direct_list)
	for conv in conversations {
		if conv.last_msg != 0 {
			q := db_query(im.db, .Conv_Set_Last, i64(conv.id), i64(conv.last_msg))
			if !db_run(im.db, q) {
				log.errorf("could not set the last message of %s", conv.name)
				return false
			}
		}
	}
	return true
}

// import_post reads one post or reply and writes it. What it needed for that is
// let go of at the end, and nothing that was in the temp allocator before is.
@(private = "file")
import_post :: proc(
	im: ^Importer,
	reader: ^mattermost.Post_Reader,
	ref: mattermost.Post_Ref,
) -> bool {
	temp := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp)
	body, read := mattermost.post_read(reader, ref)
	if !read {
		log.errorf("could not read the post at byte %d of import.jsonl again", ref.offset)
		return false
	}
	return import_message(im, ref, body)
}

// import_message writes one post or reply. A post that has nothing that can be
// imported yet is left out, and counted. It returns false only if the database
// failed.
@(private = "file")
import_message :: proc(
	im: ^Importer,
	ref: mattermost.Post_Ref,
	body: mattermost.Post_Body,
) -> bool {
	s := im.scan
	a := virtual.arena_allocator(&s.arena)
	conv := im.direct_list[ref.conv] if ref.direct else im.channels[ref.conv]
	sender, known := im.ids[body.user]
	if !known || conv == nil {
		mattermost.note(s, .Post_Failed, body.user, a)
		return true
	}
	m := proto.Message {
		conv   = conv.id,
		sender = sender,
		time   = proto.Unix_Ms(body.create_at),
		edited = proto.Unix_Ms(body.edit_at),
	}

	has_header := !ref.direct && strings.trim_space(s.channels[ref.conv].header) != ""
	system, result := mattermost.map_system(
		body.type,
		body.message,
		body.props,
		has_header,
		context.temp_allocator,
	)
	if result == .Incomplete && body.type == "system_change_chan_privacy" && !ref.direct {
		// The text isn't English: the direction comes from the channel (the scan).
		if private, found := s.privacy_dir[{int(ref.conv), body.create_at}]; found {
			system, result = {
					what = .Made_Private if private else .Made_Public,
				}, .Mapped
		}
	}
	switch result {
	case .Dropped, .Unknown:
		// Counted by type already (the plan).
		return true
	case .Incomplete:
		mattermost.note(s, .System_Skipped, body.type, a)
		return true
	case .Mapped:
		m.kind = .System
		m.system = u8(system.what)
		m.text = system.text
		if system.arg != "" {
			target, found := im.ids[system.arg]
			if !found {
				mattermost.note(
					s,
					.System_Skipped,
					fmt.tprintf("%s: %s", body.type, system.arg),
					a,
				)
				return true
			}
			m.system_arg = u32(target)
		}
		if system.who != "" {
			who, found := im.ids[system.who]
			if !found {
				mattermost.note(
					s,
					.System_Skipped,
					fmt.tprintf("%s: %s", body.type, system.who),
					a,
				)
				return true
			}
			m.sender = who
		}
	case .Not_System:
		text, cut := mattermost.clean_message(body.message)
		if cut {
			mattermost.note(s, .Text_Cut, body.user, a)
		}
		if text == "" {
			mattermost.note(s, .Post_Empty, body.type if body.type != "" else "(no type)", a)
			return true
		}
		m.kind = .Text
		m.text = text
		if body.is_pinned {
			m.flags += {.Pinned}
		}
	}

	// A reply belongs to its post's thread, if that was imported.
	if ref.reply >= 0 {
		if root, found := im.roots[ref.offset]; found {
			m.thread_root = root
		} else {
			mattermost.note(s, .Thread_Root_Missing, body.user, a)
		}
	}
	if !msg_insert(im.db, &m, 0) {
		log.errorf("could not write a message of %s", body.user)
		return false
	}
	if ref.reply < 0 && body.replies > 0 {
		im.roots[ref.offset] = m.id
	}
	conv.last_msg, conv.last_time = m.id, m.time
	im.messages += 1
	if m.kind == .Text {
		return import_extras(im, ref, body, m, conv)
	}
	return true
}

// import_extras writes what hangs on a message: its reactions, its pin and the
// accounts that saved it (D15).
@(private = "file")
import_extras :: proc(
	im: ^Importer,
	ref: mattermost.Post_Ref,
	body: mattermost.Post_Body,
	m: proto.Message,
	conv: ^Conv,
) -> bool {
	s := im.scan
	a := virtual.arena_allocator(&s.arena)

	// Reactions: those of the post, and for the first post of a direct channel
	// the ones that extras.jsonl has, which the export leaves out.
	reactions := body.reactions
	if ref.direct && ref.reply < 0 && len(s.extra_reactions) > 0 {
		key := mattermost.extra_key(im.direct_keys[ref.conv], body.user, body.create_at)
		if extra, found := s.extra_reactions[key]; found {
			reactions = extra
		}
	}
	// A message has at most MAX_REACTIONS different emoji, and an account
	// counts once for each, however many names of it it used (`+1` and
	// `thumbsup` are one emoji).
	different := make(map[string]bool, context.temp_allocator)
	for r in reactions {
		account, known := im.ids[r.user]
		if !known {
			mattermost.note_once(s, .Reaction_User_Gone, r.user, a)
			continue
		}
		emoji, result := mattermost.map_reaction(
			&s.plan.emoji,
			r.emoji_name,
			context.temp_allocator,
		)
		if result == .Unknown {
			continue // said by the plan
		}
		if emoji not_in different {
			if len(different) >= proto.MAX_REACTIONS {
				mattermost.note(s, .Reactions_Cut, emoji, a)
				continue
			}
			different[emoji] = true
		}
		q := db_query(im.db, .React_Add, i64(m.id), emoji, i64(account), r.create_at)
		if !db_run(im.db, q) {
			log.errorf("could not write a reaction to a message of %s", body.user)
			return false
		}
	}

	// A pin. Who pinned it isn't in the export, so the author did.
	if .Pinned in m.flags {
		q := db_query(im.db, .Pin_Add, i64(conv.id), i64(m.id), i64(m.sender), i64(m.time))
		if !db_run(im.db, q) {
			log.error("could not write a pin")
			return false
		}
	}

	// Saved posts become bookmarks, at the post's own time: the export doesn't
	// say when it was saved.
	for name in body.flagged_by {
		account, known := im.ids[name]
		if !known {
			mattermost.note_once(s, .Saved_User_Gone, name, a)
			continue
		}
		q := db_query(im.db, .Bookmark_Add, i64(account), i64(m.id), i64(m.time))
		if !db_run(im.db, q) {
			log.error("could not write a bookmark")
			return false
		}
	}
	return true
}

// import_limits keeps to what yap allows once all the messages are there: at
// most MAX_PINS pins in a conversation and MAX_BOOKMARKS saved posts for an
// account, the newest of them. A message that loses its pin is no longer
// marked as pinned.
@(private = "file")
import_limits :: proc(im: ^Importer) -> bool {
	s := im.scan
	a := virtual.arena_allocator(&s.arena)
	count :: proc(im: ^Importer, sql: string) -> i64 {
		n, _ := db_pragma_int(im.db, sql)
		return n
	}
	// The pins and saved posts beyond the limits, newest first.
	ok := db_exec(
		im.db,
		fmt.tprintf(
			`CREATE TEMP TABLE over_pins AS SELECT conv, message FROM (SELECT conv, message, row_number() OVER (PARTITION BY conv ORDER BY time DESC, message DESC) AS n FROM pins) WHERE n > %d;
			CREATE TEMP TABLE over_bookmarks AS SELECT account, message FROM (SELECT account, message, row_number() OVER (PARTITION BY account ORDER BY time DESC, message DESC) AS n FROM bookmarks) WHERE n > %d`,
			proto.MAX_PINS,
			proto.MAX_BOOKMARKS,
		),
	)
	if !ok {
		log.error("could not look for pins and saved posts over the limits")
		return false
	}
	pins := count(im, "SELECT count(*) FROM over_pins")
	bookmarks := count(im, "SELECT count(*) FROM over_bookmarks")
	if pins > 0 {
		ok = db_exec(
			im.db,
			"UPDATE messages SET flags = flags & ~2 WHERE id IN (SELECT message FROM over_pins); DELETE FROM pins WHERE message IN (SELECT message FROM over_pins)",
		)
		for _ in 0 ..< pins {
			mattermost.note(s, .Pins_Cut, "pins of a conversation", a)
		}
	}
	if ok && bookmarks > 0 {
		ok = db_exec(
			im.db,
			"DELETE FROM bookmarks WHERE (account, message) IN (SELECT account, message FROM over_bookmarks)",
		)
		for _ in 0 ..< bookmarks {
			mattermost.note(s, .Bookmarks_Cut, "saved posts of an account", a)
		}
	}
	db_exec(im.db, "DROP TABLE over_pins; DROP TABLE over_bookmarks")
	im.reactions = int(count(im, "SELECT count(*) FROM reactions"))
	im.pins = int(count(im, "SELECT count(*) FROM pins"))
	im.bookmarks = int(count(im, "SELECT count(*) FROM bookmarks"))
	if !ok {
		log.error("could not keep pins and saved posts to the limits")
	}
	return ok
}
