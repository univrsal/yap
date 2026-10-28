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
	return true
}
