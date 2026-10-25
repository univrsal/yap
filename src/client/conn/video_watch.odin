package conn

import log "common:wlog"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"

import "client:video"
import "common:proto"

// Watching: which streams we ask for, and showing what arrives.

// Watch somebody's screen, or nobody's (0).
Watch_Command :: struct {
	user: proto.User_Num,
}

// Watch the cameras of these users, and no others, each in a tile of that
// size in pixels (0 if not known). A user whose camera is off stays in the
// list and is watched once it comes on.
Watch_Cameras_Command :: struct {
	users: [proto.MAX_CAMERAS]proto.User_Num,
	tiles: [proto.MAX_CAMERAS][2]int,
	count: int,
}

// Watch the cameras of the users of these accounts (names separated by spaces,
// owned), and no others: the headless client's /cameras.
Watch_Camera_Names_Command :: struct {
	names: string,
}

// video_watch_camera_names watches the cameras of the named accounts' users.
video_watch_camera_names :: proc(c: ^Server_Conn, names: string) {
	users := make([dynamic]proto.User_Num, context.temp_allocator)
	for name in strings.fields(names, context.temp_allocator) {
		account := account_named(c, name)
		if account == 0 {
			log.warnf("there's no account %q", name)
			continue
		}
		for u in c.channels.state.users {
			if u.account == account {
				append(&users, u.num)
			}
		}
	}
	video_watch_cameras(c, users[:], nil)
	log.infof("watching %d cameras", len(users))
}

// watch_cameras makes the command that watches the cameras of `users` (the
// first MAX_CAMERAS of them).
watch_cameras :: proc(users: ..proto.User_Num) -> (cmd: Watch_Cameras_Command) {
	cmd.count = copy(cmd.users[:], users)
	return
}

// video_watch starts watching `user`'s screen, or stops watching any when
// `user` is 0.
video_watch :: proc(c: ^Server_Conn, user: proto.User_Num) {
	in_ := &c.video.ins[0]
	if user == in_.key.user {
		return
	}
	if in_.key.user != 0 {
		in_stop(c, in_)
	}
	if user != 0 {
		in_start(in_, {user, .Screen})
	}
	log.infof("watching %s", display_name(c, user) if user != 0 else "nobody")
	publish_watching(c)
}

// video_watch_cameras watches the cameras of `users`, each in a tile of the
// size `tiles` says (none if nil), and stops watching all others.
video_watch_cameras :: proc(c: ^Server_Conn, users: []proto.User_Num, tiles: [][2]int) {
	v := &c.video
	for &in_ in v.ins[1:] {
		if in_.key.user != 0 && !slice.contains(users, in_.key.user) {
			in_stop(c, &in_)
		}
	}
	next: for user, i in users {
		if user == 0 {
			continue
		}
		tile := tiles[i] if i < len(tiles) else {}
		free_in: ^Video_In
		for &in_ in v.ins[1:] {
			if in_.key.user == user {
				in_.tile = tile
				continue next
			}
			if in_.key.user == 0 && free_in == nil {
				free_in = &in_
			}
		}
		if free_in == nil {
			break // more than MAX_CAMERAS
		}
		in_start(free_in, {user, .Camera})
		free_in.tile = tile
	}
}

@(private = "file")
in_start :: proc(in_: ^Video_In, key: video.Key) {
	window := in_.window if in_.window != nil else new(proto.Video_Window)
	in_^ = {
		key    = key,
		window = window,
	}
	proto.video_window_reset(window)
	window.reliable = video.MEDIA_RELIABLE
}

// in_stop stops watching a stream, ending its lease at once rather than when
// it runs out, and lets go of what it took.
@(private = "file")
in_stop :: proc(c: ^Server_Conn, in_: ^Video_In) {
	if in_.watching {
		buf: [proto.WATCH_TILE_SIZE]u8
		send_watch(c, proto.encode_watch(&buf, in_.key.user, false, in_.key.stream, stop = true))
	}
	video.show_end(in_.key)
	in_free(in_)
}

in_free :: proc(in_: ^Video_In) {
	if in_.window != nil {
		proto.video_window_destroy(in_.window)
		free(in_.window)
	}
	in_^ = {}
}

// drive_watch drives each stream we watch (drive_in).
drive_watch :: proc(c: ^Server_Conn) {
	if !c.channels.have_state {
		return
	}
	for &in_ in c.video.ins {
		if in_.key.user != 0 {
			drive_in(c, &in_)
		}
	}
}

// drive_in renews the lease on a stream, asks again for whatever has gone
// missing, and asks for a keyframe while the incoming frames cannot be decoded.
// A screen that is no longer shared or whose sharer leaves the channel is no
// longer watched, and a camera that goes off waits until it comes on again.
@(private = "file")
drive_in :: proc(c: ^Server_Conn, in_: ^Video_In) {
	if !can_watch(c, in_.key) {
		if in_.key.stream == .Screen {
			video_watch(c, 0)
		} else if in_.watching {
			// Its lease runs out by itself.
			video.show_end(in_.key)
			proto.video_window_reset(in_.window)
			in_.watching, in_.last_watch, in_.last_key_asked = false, {}, {}
		}
		return
	}
	in_.watching = true
	if video.show_failed(in_.key) {
		// Whatever the decoder had is gone, so start again from a keyframe.
		log.infof("video: %s's decoder failed", in_name(c, in_.key))
		proto.video_window_reset(in_.window)
	}
	for n in proto.video_window_nacks(in_.window, time.tick_now(), c.media.has_current) {
		buf: [proto.NACK_CAMERA_SIZE]u8
		link_send(&c.media.link, proto.encode_nack(&buf, in_.key.user, n, in_.key.stream))
	}
	// Giving up may have let the frames behind it through.
	show_frames(in_)
	log_break(c, in_)
	need_key := in_.window.broken
	due := time.tick_since(in_.last_watch) >= proto.WATCH_RESEND
	if need_key && time.tick_since(in_.last_key_asked) >= proto.KEYFRAME_REQUEST_MIN {
		due = true
		in_.last_key_asked = time.tick_now()
	}
	// A server that takes tile sizes hears of a new one soon (but not at every
	// step of a window being resized).
	tile := in_.tile if c.rpc.server.demand && in_.key.stream == .Camera else {}
	if tile != in_.tile_sent && time.tick_since(in_.last_watch) >= WATCH_TILE_EVERY {
		due = true
	}
	if !due {
		return
	}
	buf: [proto.WATCH_TILE_SIZE]u8
	send_watch(c, proto.encode_watch(&buf, in_.key.user, need_key, in_.key.stream, tile = tile))
	in_.last_watch = time.tick_now()
	in_.tile_sent = tile
}

// log_break logs why the frames of a stream we watch can no longer be decoded,
// which asks for a keyframe and leaves the picture still until it comes.
@(private = "file")
log_break :: proc(c: ^Server_Conn, in_: ^Video_In) {
	w := in_.window
	if w.breaks == 0 {
		return
	}
	b := w.last_break
	more := fmt.tprintf(" (and %d more)", w.breaks - 1) if w.breaks > 1 else ""
	w.breaks = 0
	if b.pushed_out > 0 {
		log.debugf(
			"video: %s broke at frame %d: %d frames pushed out of the window%s",
			in_name(c, in_.key),
			b.frame,
			b.pushed_out,
			more,
		)
		return
	}
	log.debugf(
		"video: %s broke at frame %d: gave up on it with %d of %d fragments%s after %d Nack rounds, %.0f ms after its gap was seen, %.0f ms after its last fragment%s",
		in_name(c, in_.key),
		b.frame,
		b.received,
		b.count,
		" (a keyframe)" if b.key else "",
		b.rounds,
		time.duration_milliseconds(b.waited),
		time.duration_milliseconds(b.idle),
		more,
	)
}

// in_name names a stream we watch for the log.
@(private = "file")
in_name :: proc(c: ^Server_Conn, key: video.Key) -> string {
	return fmt.tprintf(
		"%s's %s",
		display_name(c, key.user),
		"camera" if key.stream == .Camera else "screen",
	)
}

// send_watch sends a Watch, if there is a media link to send it on.
@(private = "file")
send_watch :: proc(c: ^Server_Conn, msg: []u8) {
	if c.media.has_current {
		link_send(&c.media.link, msg)
	}
}

// can_watch says whether `key`'s stream is on, its user is in our voice room,
// and is not us.
can_watch :: proc(c: ^Server_Conn, key: video.Key) -> bool {
	ch := &c.channels
	if !ch.have_state || key.user == ch.state.your_user {
		return false
	}
	u := proto.find_user(&ch.state, key.user)
	if u == nil || proto.stream_flag(key.stream) not_in u.flags {
		return false
	}
	room := my_room(c)
	return room != 0 && u.room == room
}

handle_video :: proc(c: ^Server_Conn, pt: []u8) {
	v := &c.video
	sharer, f, ok := proto.decode_video_down(pt)
	if !ok || sharer == 0 {
		return
	}
	key := video.Key{sharer, f.stream}
	in_: ^Video_In
	for &candidate in v.ins {
		if candidate.key == key && candidate.watching {
			in_ = &candidate
			break
		}
	}
	if in_ == nil {
		return
	}
	v.bytes_in += len(pt)
	in_.stats_in += len(pt)
	in_.stats_frags += 1
	now := time.tick_now()
	if f.index == 0 {
		note_delay(in_, f.ts, now)
	}
	proto.video_window_add(in_.window, f, now)
	show_frames(in_)
}

// show_frames hands what a stream's window has ready to its decoder. While it
// has none yet (video.show_ready: the desktop makes it when the UI first draws
// the stream), the frames are dropped. Once it has, it starts from a keyframe:
// anything else resets the window, which asks for one.
@(private = "file")
show_frames :: proc(in_: ^Video_In) {
	ready := video.show_ready(in_.key)
	for {
		frame := proto.video_window_pop(in_.window) or_break
		if !ready {
			in_.dropped = true
			continue
		}
		if in_.dropped && !frame.key {
			proto.video_window_reset(in_.window)
			break
		}
		in_.dropped = false
		in_.last_codec = frame.codec
		video.show_frame(in_.key, frame)
	}
}
