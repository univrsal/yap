package stress

import "core:crypto/ecdh"
import "core:encoding/endian"
import "core:log"
import "core:time"

import "common:."
import "common:lite"
import "common:proto"

// A bot is one connection to the server (common/lite), which looks like a
// client to the server, plus voice, which lite leaves to its owner. It logs
// in as bot<n> with the password it was given the first time, and with its
// device's key from then on.
//
// Its voice frames aren't Opus, since the server never looks inside them.
// They contain the time they were sent and are padded to the size of an
// Opus frame. All bots run in this one process on one clock, so a frame
// that arrives shows how long the server took to pass it on.

// How many times a login that was rejected for now (too many at once for
// the server's password hashing) is retried.
LOGIN_RETRIES :: 100
// What a voice frame contains before its padding: the time it was sent.
FRAME_STAMP_SIZE :: 8
FRAME_TIME :: 20 * time.Millisecond

Bot :: struct {
	run:         ^Run,
	name:        string,
	key_path:    string,
	client:      lite.Client,
	opened:      bool, // whether the client is open; it opens when it's the bot's turn
	connect_at:  time.Tick, // when it may start connecting
	started:     time.Tick, // when it actually started
	been_ready:  bool,
	home:        proto.Conv_Id, // the channel everyone is in
	wants_voice: bool,
	talker:      bool,
	in_voice:    bool,
	join_asked:  bool,
	seq:         u32,
	next_frame:  time.Tick,
	// The last sequence number heard from each speaker, to detect gaps.
	heard:       map[proto.User_Num]u32,
}

@(private = "file")
HANDLERS :: lite.Handlers {
	phase   = bot_phase,
	event   = bot_event,
	message = bot_message,
}

bot_close :: proc(b: ^Bot) {
	if b.opened {
		lite.close(&b.client)
	}
	delete(b.heard)
}

// bot_ready returns whether the bot can be given work, which requires it to
// be logged in and to know the home channel.
bot_ready :: proc(b: ^Bot) -> bool {
	return b.opened && lite.ready(&b.client) && b.home != 0
}

// bot_step does whatever is due: connecting when it's the bot's turn,
// running the connection, joining the voice room and sending voice.
bot_step :: proc(b: ^Bot, now: time.Tick) {
	if !b.opened {
		if time.tick_diff(b.connect_at, now) < 0 || !bot_open(b) {
			return
		}
		b.started = now
	}
	c := &b.client
	lite.step(c, now)
	if !lite.ready(c) {
		return
	}
	if b.wants_voice && !b.join_asked && b.home != 0 {
		room_buf: [4]u8
		b.join_asked = lite.request(
			c,
			.Voice_Join,
			proto.encode_room(&room_buf, proto.Room(b.home)),
			bot_answered,
		)
	}
	if b.talker && b.in_voice {
		send_voice(b, now)
	}
}

// bot_receive handles whatever packets have arrived.
bot_receive :: proc(b: ^Bot) {
	if b.opened {
		lite.receive(&b.client)
	}
}

// bot_ask sends a request and records its answer in the stats.
bot_ask :: proc(b: ^Bot, op: proto.Request_Op, body: []u8) {
	if !lite.request(&b.client, op, body, bot_answered) {
		log.warnf("%s: %v not sent", b.name, op)
	}
}

@(private = "file")
bot_open :: proc(b: ^Bot) -> bool {
	key: ecdh.Private_Key
	defer ecdh.private_key_clear(&key)
	if !common.load_or_create_private_key(b.key_path, &key) {
		log.errorf("%s: could not load or make the key %s", b.name, b.key_path)
		b.connect_at = time.tick_add(b.connect_at, time.Hour)
		return false
	}
	opt := lite.Options {
		server         = b.run.server,
		password       = b.run.opt.password,
		username       = b.name,
		login_password = b.run.opt.bot_password,
		device         = "stress",
		agent          = "yap-stress",
		login_retries  = LOGIN_RETRIES,
		name           = b.name,
		handlers       = HANDLERS,
		user           = b,
	}
	if !lite.open(&b.client, &key, opt) {
		b.connect_at = time.tick_add(b.connect_at, time.Hour)
		return false
	}
	b.opened = true
	return true
}

@(private = "file")
bot_phase :: proc(c: ^lite.Client, phase: lite.Phase) {
	b := (^Bot)(c.opt.user)
	#partial switch phase {
	case .Syncing:
		// This is a new connection (or our first), so nothing from the old
		// one applies any more.
		if b.been_ready {
			b.run.stats.reconnects += 1
		}
		b.in_voice, b.join_asked = false, false
	case .Ready:
		if !b.been_ready {
			b.been_ready = true
			ready_after(b.run, time.tick_since(b.started))
		}
	case .Failed:
		b.in_voice = false
		b.run.stats.failed += 1
		if c.failure == .Login_Failed &&
		   (c.login_status == .Wrong_Password || c.login_status == .Denied) {
			log.errorf(
				"%s can't log in (%v): make the bots with yap-server account bots",
				b.name,
				c.login_status,
			)
		} else {
			log.errorf("%s gave up: %v", b.name, c.failure)
		}
	}
}

@(private = "file")
bot_event :: proc(c: ^lite.Client, op: proto.Event_Op, body: []u8) {
	b := (^Bot)(c.opt.user)
	if op == .Conv_Changed {
		if conv, ok := proto.decode_conv(body); ok && .Home in conv.flags {
			b.home = conv.id
		}
	}
}

@(private = "file")
bot_message :: proc(c: ^lite.Client, kind: proto.Message_Kind, pt: []u8) {
	b := (^Bot)(c.opt.user)
	if kind != .Voice || len(pt) < proto.VOICE_DOWN_HEADER_SIZE + FRAME_STAMP_SIZE {
		return
	}
	speaker := proto.User_Num(endian.unchecked_get_u32le(pt[1:]))
	seq := endian.unchecked_get_u32le(pt[5:])
	sent := time.Tick {
		_nsec = i64(endian.unchecked_get_u64le(pt[proto.VOICE_DOWN_HEADER_SIZE:])),
	}
	if last, ok := b.heard[speaker]; ok && seq > last + 1 {
		b.run.stats.frames_missing += int(seq - last - 1)
	}
	if last, ok := b.heard[speaker]; !ok || seq > last {
		b.heard[speaker] = seq
	}
	frame_heard(b.run, time.tick_since(sent))
}

@(private = "file")
bot_answered :: proc(c: ^lite.Client, a: lite.Answer) {
	b := (^Bot)(c.opt.user)
	if a.status == .Reset {
		return // lost together with its connection, not actually answered
	}
	answered(b.run, a.op, a.status, a.took)
	if a.op != .Voice_Join {
		return
	}
	if a.status == .Ok {
		b.in_voice = true
		b.next_frame = time.tick_now()
	} else {
		log.errorf("%s could not join the voice room: %v", b.name, a.status)
	}
}

// send_voice sends the frames that are due by now, 20 ms apart.
@(private = "file")
send_voice :: proc(b: ^Bot, now: time.Tick) {
	size := clamp(b.run.opt.frame, FRAME_STAMP_SIZE, 1000)
	buf: [proto.VOICE_UP_HEADER_SIZE + 1000]u8
	for time.tick_diff(b.next_frame, now) >= 0 {
		b.next_frame = time.tick_add(b.next_frame, FRAME_TIME)
		buf[0] = u8(proto.Message_Kind.Voice)
		endian.unchecked_put_u32le(buf[1:], b.seq)
		b.seq += 1
		stamp := time.tick_now()
		endian.unchecked_put_u64le(buf[proto.VOICE_UP_HEADER_SIZE:], u64(stamp._nsec))
		lite.send(&b.client, buf[:proto.VOICE_UP_HEADER_SIZE + size])
		b.run.stats.frames_sent += 1
	}
}
