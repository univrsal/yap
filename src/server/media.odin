package server

import "core:crypto/ecdh"
import "core:log"
import "core:net"
import "core:sync"
import "core:thread"
import "core:time"

import "common:."
import "common:proto"

/*
The media link (proto.Link.Media): screen sharing, all of it, on a UDP
port and a thread of its own, so a shared screen's
thousands of packets a second never pass through the main loop, and the
main loop's turns never hold a frame up.

It also repairs losses: it keeps the last `cache_ms` (half a second) of
each sharer's fragments, as they went out, and a viewer that finds some
missing asks for them by number (proto.Nack, video_window.odin), which
costs a round trip to the server and nothing of the sharer's upload.

And it lets a share's bitrate follow its viewers: each reports how the
share reaches it (proto.Report, video_report.odin), and once a second
each sharer is told the worst of its viewers' reports (media_reports),
less one far behind the rest.

A client opens it once its connection is logged in, to the port
Server_Info names, with a handshake like the bulk link's: a hello with
the connection's conn_id and link = Media, which the thread accepts if
the device has a logged in connection of that conn_id. A browser's
comes through the relay (relay.odin). It sends its video on it, and its
Watch leases; it gets the video it watches on it, and the Keyframe
requests for its own share. Without it there's no screen sharing: the
main loop drops any video that comes its way.

What the thread knows about the connections is a table the main loop
publishes whenever its state version moves (media_sync): who is who,
in which room, sharing or not. Everything else, the sessions, leases,
budgets and keyframe requests of the media link, is the thread's own.
*/

// Who a connection is, as the media thread needs to know it.
Media_Peer :: struct {
	num:      proto.User_Num,
	conn_id:  u64,
	instance: u64,
	room:     proto.Room,
	sharing:  bool,
}

Media_Session :: struct {
	using session: proto.Session,
	handshake:     proto.Responder, // in use until keyed
	keyed:         bool,
	confirmed:     bool,
	superseded:    bool,
	endpoint:      net.Endpoint,
	started:       time.Tick,
	last_recv:     time.Tick,
	num:           proto.User_Num, // whose, once keyed
	// The lease on whom this session's connection watches.
	watching:      proto.User_Num,
	watch_until:   time.Tick,
	// What it may have sent again (Nack), as for a sharer's budget.
	resend_budget: int,
	resend_at:     time.Tick,
	// Its last Report, on whom, and when.
	report:        proto.Video_Report,
	report_of:     proto.User_Num,
	report_at:     time.Tick,
}

// A Report older than this isn't counted: its viewer went quiet.
@(private = "file")
REPORT_FRESH :: 3 * time.Second

// A sharer's budget, keyframe requests and recent fragments on the
// media link.
Media_Sharer :: struct {
	budget:        int,
	budget_at:     time.Tick,
	last_key_sent: time.Tick,
	cache:         ^Media_Cache, // made with the first fragment
}

/*
Media_Cache is a sharer's fragments as they went out (the Video message
viewers get), in a ring of MEDIA_CACHE_SLOTS, found by frame and index.
What's older than the cache's age is never sent again, though it may
still be in the ring.
*/
MEDIA_CACHE_SLOTS :: 2048

Media_Cached :: struct {
	key:  u64, // frame << 16 | index
	at:   time.Tick,
	size: int,
	data: [proto.MAX_PAYLOAD_SIZE]u8,
}

Media_Cache :: struct {
	slots: [MEDIA_CACHE_SLOTS]Media_Cached,
	next:  int,
	index: map[u64]int, // key -> slot
}

Media :: struct {
	enabled:      bool,
	port:         int,
	max_rate:     int, // bytes a second, per sharer
	max_burst:    int,
	max_sessions: int,
	cache_age:    time.Duration, // how long fragments are kept for Nacks
	password:     string, // the server's
	key:          ecdh.Private_Key, // the server's, a copy for the thread
	sock:         net.UDP_Socket,
	thread:       ^thread.Thread,
	stop:         bool, // atomic

	// The main loop's to write, the thread's to read, under `mutex`.
	mutex:        sync.Mutex,
	peers:        map[[proto.KEY_SIZE]byte]Media_Peer,

	// The main loop's own: what it last published.
	published:    u32,
	published_at: time.Tick,

	// The thread's own.
	sessions:     map[proto.Session_Id]^Media_Session,
	sharers:      map[proto.User_Num]Media_Sharer,
	housekept:    time.Tick,
}

// How often the main loop publishes even when its version hasn't
// moved, and the thread looks for sessions to drop.
@(private = "file")
MEDIA_HOUSEKEEPING :: 1 * time.Second
// How long the thread waits for a packet before it comes round anyway.
@(private = "file")
MEDIA_WAIT :: 100 * time.Millisecond

// media_port is the media link's port as `settings` have it; 0 if it's off.
media_port :: proc(settings: Settings) -> int {
	cfg := settings.video
	if !cfg.enabled {
		return 0
	}
	return cfg.port if cfg.port != 0 else settings.port + 1
}

/*
media_open opens the media link's port and starts its thread, if the
config has it. Without it, or if the port can't be had, desktop clients
share over their bulk links as before.
*/
media_open :: proc(s: ^Server, settings: Settings) {
	m := &s.media
	cfg := settings.video
	if !cfg.enabled {
		log.info("the media link is off, and with it screen sharing")
		return
	}
	m.port = media_port(settings)
	m.max_rate = cfg.max_kbit * 1000 / 8
	m.max_burst = proto.MAX_VIDEO_FRAME_SIZE + 64 * 1024
	m.max_sessions = s.max_sessions
	m.cache_age = time.Duration(cfg.cache_ms) * time.Millisecond
	m.password = s.password
	m.key = s.key
	sock, err := net.make_bound_udp_socket(net.IP4_Any, m.port)
	if err != nil {
		log.errorf(
			"the media link can't have udp port %d (%v): there's no screen sharing",
			m.port,
			err,
		)
		return
	}
	m.sock = sock
	net.set_option(sock, .Receive_Timeout, MEDIA_WAIT)
	// A keyframe arrives as hundreds of packets at once.
	net.set_option(sock, .Receive_Buffer_Size, 8 * 1024 * 1024)
	net.set_option(sock, .Send_Buffer_Size, 8 * 1024 * 1024)
	m.enabled = true
	media_publish(s)
	m.thread = thread.create_and_start_with_poly_data(m, media_run, init_context = context)
	log.infof("media link on udp :%d, %d kbit/s a sharer", m.port, cfg.max_kbit)
}

media_close :: proc(s: ^Server) {
	m := &s.media
	if !m.enabled {
		return
	}
	sync.atomic_store(&m.stop, true)
	thread.join(m.thread)
	thread.destroy(m.thread)
	net.close(m.sock)
	media_free(m)
	ecdh.private_key_clear(&m.key)
	m^ = {}
}

// media_free frees what the thread made.
media_free :: proc(m: ^Media) {
	for _, ms in m.sessions {
		free(ms)
	}
	for _, &sh in m.sharers {
		cache_free(&sh)
	}
	delete(m.sessions)
	delete(m.sharers)
	delete(m.peers)
}

@(private = "file")
cache_free :: proc(sh: ^Media_Sharer) {
	if sh.cache != nil {
		delete(sh.cache.index)
		free(sh.cache)
		sh.cache = nil
	}
}

/*
media_sync publishes the connections to the thread when anything
clients see has changed (the state version), and every second anyway.
A sync phase of the main loop.
*/
media_sync :: proc(s: ^Server) {
	m := &s.media
	if !m.enabled {
		return
	}
	if m.published == s.version && time.tick_since(m.published_at) < MEDIA_HOUSEKEEPING {
		return
	}
	media_publish(s)
}

@(private = "file")
media_publish :: proc(s: ^Server) {
	m := &s.media
	sync.guard(&m.mutex)
	clear(&m.peers)
	// Only connections that are logged in, and seen: the others may do
	// nothing but log in.
	for key, u in s.conns {
		if u.account == nil || .Unverified in u.account.flags {
			continue
		}
		m.peers[key] = {
			num      = u.num,
			conn_id  = u.conn_id,
			instance = u.instance,
			room     = u.room,
			sharing  = .Sharing in u.flags,
		}
	}
	m.published = s.version
	m.published_at = time.tick_now()
}

// The thread.
@(private = "file")
media_run :: proc(m: ^Media) {
	buf: [proto.MAX_PACKET_SIZE]byte
	for !sync.atomic_load(&m.stop) {
		free_all(context.temp_allocator)
		n, from, err := net.recv_udp(m.sock, buf[:])
		if err == nil && !common.simulate_loss() {
			sync.guard(&m.mutex)
			media_handle_packet(m, buf[:n], from)
		}
		if time.tick_since(m.housekept) >= MEDIA_HOUSEKEEPING {
			sync.guard(&m.mutex)
			media_housekeeping(m)
			media_reports(m)
			m.housekept = time.tick_now()
		}
	}
}

// media_handle_packet handles one packet off the media port. With
// `m.mutex` held.
media_handle_packet :: proc(m: ^Media, packet: []byte, from: net.Endpoint) {
	#partial switch proto.packet_type(packet) {
	case .Handshake_Init:
		media_init(m, packet, from)
	case .Handshake_Finish:
		media_finish(m, packet, from)
	case .Data:
		media_data(m, packet, from)
	}
}

@(private = "file")
media_init :: proc(m: ^Media, packet: []byte, from: net.Endpoint) {
	sender_idx := proto.init_sender_index(packet)
	for _, ms in m.sessions {
		if !ms.keyed && ms.handshake.remote_idx == sender_idx && ms.endpoint == from {
			net.send_udp(m.sock, ms.handshake.packet[:], from)
			return
		}
	}
	if len(m.sessions) >= m.max_sessions {
		log.warnf("media: session table full, ignoring a handshake from %v", net.to_string(from))
		return
	}
	idx: proto.Session_Id
	for {
		idx = proto.random_index()
		if idx not_in m.sessions {
			break
		}
	}
	ms := new(Media_Session)
	resp, ok := proto.responder_start(&ms.handshake, &m.key, packet, idx)
	if !ok {
		free(ms)
		return
	}
	ms.endpoint = from
	ms.started = time.tick_now()
	m.sessions[idx] = ms
	net.send_udp(m.sock, resp, from)
}

@(private = "file")
media_finish :: proc(m: ^Media, packet: []byte, from: net.Endpoint) {
	idx := proto.receiver_index(packet)
	ms := m.sessions[idx] or_else nil
	if ms == nil {
		return
	}
	peer, known := m.peers[ms.peer_key]
	if ms.keyed {
		// The Welcome got lost: again, to the address we know.
		media_welcome(m, ms, peer.instance)
		return
	}
	payload, ok := proto.responder_finish(&ms.handshake, packet, &ms.session)
	if !ok {
		media_drop(m, idx)
		return
	}
	conn_id, hello_password, link, hello_ok := proto.decode_hello(payload)
	peer, known = m.peers[ms.peer_key]
	switch {
	case !hello_ok || link != .Media:
		media_refuse(m, ms, from, .Version)
		return
	case m.password != "" && !password_matches(m.password, hello_password):
		media_refuse(m, ms, from, .Wrong_Password)
		return
	case !known || peer.conn_id != conn_id:
		media_refuse(m, ms, from, .No_Connection)
		return
	}
	ms.keyed = true
	ms.endpoint = from
	ms.last_recv = time.tick_now()
	ms.num = peer.num
	for _, other in m.sessions {
		if other != ms && other.keyed && other.peer_key == ms.peer_key {
			other.superseded = true
		}
	}
	log.debugf("media: %08x has a new media link", common.key_id(ms.peer_key))
	media_welcome(m, ms, peer.instance)
}

// How many copies of a Welcome or Refused go out: they're unreliable.
@(private = "file")
MEDIA_COPIES :: 3

@(private = "file")
media_welcome :: proc(m: ^Media, ms: ^Media_Session, instance: u64) {
	buf: [proto.WELCOME_SIZE]u8
	msg := proto.encode_welcome(&buf, instance, true)
	for _ in 0 ..< MEDIA_COPIES {
		media_send(m, ms, msg)
	}
}

@(private = "file")
media_refuse :: proc(m: ^Media, ms: ^Media_Session, from: net.Endpoint, reason: proto.Refusal) {
	log.debugf("media: refused %08x: %v", common.key_id(ms.peer_key), reason)
	buf: [proto.REFUSED_SIZE]byte
	msg := proto.encode_refused(&buf, reason)
	pkt_buf: [proto.MAX_PACKET_SIZE]byte
	for _ in 0 ..< MEDIA_COPIES {
		if pkt, ok := proto.seal(&ms.session, msg, pkt_buf[:]); ok {
			net.send_udp(m.sock, pkt, from)
		}
	}
	media_drop(m, ms.local_idx)
}

@(private = "file")
media_send :: proc(m: ^Media, ms: ^Media_Session, msg: []byte) {
	pkt_buf: [proto.MAX_PACKET_SIZE]byte
	if pkt, ok := proto.seal(&ms.session, msg, pkt_buf[:]); ok {
		net.send_udp(m.sock, pkt, ms.endpoint)
	}
}

@(private = "file")
media_drop :: proc(m: ^Media, idx: proto.Session_Id) {
	if ms := m.sessions[idx] or_else nil; ms != nil {
		delete_key(&m.sessions, idx)
		free(ms)
	}
}

@(private = "file")
media_data :: proc(m: ^Media, packet: []byte, from: net.Endpoint) {
	idx := proto.receiver_index(packet)
	ms := m.sessions[idx] or_else nil
	if ms == nil || !ms.keyed || time.tick_since(ms.created) > proto.REJECT_AFTER {
		return
	}
	pt_buf: [proto.MAX_PACKET_SIZE]byte
	pt, ok := proto.open(&ms.session, packet, pt_buf[:])
	if !ok {
		return
	}
	ms.endpoint = from
	ms.last_recv = time.tick_now()
	if !ms.confirmed && !ms.superseded {
		ms.confirmed = true
		stale := make([dynamic]proto.Session_Id, context.temp_allocator)
		for other_idx, other in m.sessions {
			if other != ms && other.superseded && other.peer_key == ms.peer_key {
				append(&stale, other_idx)
			}
		}
		for i in stale {
			media_drop(m, i)
		}
	}
	peer, known := m.peers[ms.peer_key]
	if !known || peer.num != ms.num {
		return // gone, or logged out; housekeeping drops it
	}
	kind, kind_ok := proto.message_kind(pt)
	if !kind_ok {
		return // keepalive
	}
	#partial switch kind {
	case .Video:
		media_relay(m, ms, peer, pt)
	case .Watch:
		media_watch(m, ms, peer, pt)
	case .Nack:
		media_nack(m, ms, peer, pt)
	case .Report:
		media_report(m, ms, pt)
	case .Ping:
		pong_buf: [proto.PING_SIZE]byte
		media_send(m, ms, proto.encode_ping(&pong_buf, .Pong, proto.decode_ping(pt)))
	}
}

/*
media_relay passes a fragment on to every media session watching its
sharer in the sharer's room, re-encrypted for each. Video from somebody
who isn't sharing, or is over their budget, goes nowhere.
*/
@(private = "file")
media_relay :: proc(m: ^Media, from: ^Media_Session, peer: Media_Peer, pt: []byte) {
	if _, ok := proto.decode_video_up(pt); !ok || !peer.sharing || peer.room == 0 {
		return
	}
	if !media_spend(m, peer.num, len(pt)) {
		log.debugf("media: %d is sharing faster than the server passes on", peer.num)
		return
	}
	out_buf: [proto.MAX_PAYLOAD_SIZE]u8
	msg := proto.video_up_to_down(&out_buf, peer.num, pt)
	now := time.tick_now()
	if m.cache_age > 0 {
		f, _ := proto.decode_video_up(pt)
		cache_put(media_sharer(m, peer.num), f.frame, f.index, msg, now)
	}
	for _, ms in m.sessions {
		if !ms.keyed || ms.superseded || ms == from || ms.watching != peer.num {
			continue
		}
		if time.tick_diff(now, ms.watch_until) <= 0 {
			continue
		}
		viewer, known := m.peers[ms.peer_key]
		if !known || viewer.room != peer.room || viewer.num == peer.num {
			continue
		}
		media_send(m, ms, msg)
	}
}

// media_sharer is what the thread keeps of a sharer, made if need be.
@(private = "file")
media_sharer :: proc(m: ^Media, num: proto.User_Num) -> ^Media_Sharer {
	sh := &m.sharers[num]
	if sh == nil {
		m.sharers[num] = {}
		sh = &m.sharers[num]
	}
	return sh
}

@(private = "file")
cache_put :: proc(sh: ^Media_Sharer, frame: u32, index: int, msg: []u8, now: time.Tick) {
	if sh.cache == nil {
		sh.cache = new(Media_Cache)
	}
	c := sh.cache
	slot := &c.slots[c.next]
	if slot.size > 0 && c.index[slot.key] == c.next {
		delete_key(&c.index, slot.key)
	}
	slot.key = u64(frame) << 16 | u64(index)
	slot.at = now
	slot.size = copy(slot.data[:], msg)
	c.index[slot.key] = c.next
	c.next = (c.next + 1) % MEDIA_CACHE_SLOTS
}

@(private = "file")
cache_get :: proc(m: ^Media, sh: ^Media_Sharer, frame: u32, index: int, now: time.Tick) -> []u8 {
	if sh == nil || sh.cache == nil {
		return nil
	}
	key := u64(frame) << 16 | u64(index)
	i, found := sh.cache.index[key]
	if !found {
		return nil
	}
	slot := &sh.cache.slots[i]
	if slot.key != key || time.tick_diff(slot.at, now) > m.cache_age {
		return nil
	}
	return slot.data[:slot.size]
}

/*
media_nack sends a viewer what it asks for again of the frame of the
sharer it's watching, from the cache, as far as its own budget (the
sharer's rate) goes: a viewer can't make the server send more than the
sharer could.
*/
@(private = "file")
media_nack :: proc(m: ^Media, ms: ^Media_Session, viewer: Media_Peer, pt: []u8) {
	sharer, n, ok := proto.decode_nack(pt)
	now := time.tick_now()
	if !ok || sharer == 0 || sharer != ms.watching || time.tick_diff(now, ms.watch_until) <= 0 {
		return
	}
	sh := m.sharers[sharer] or_else {}
	if sh.cache == nil {
		return
	}
	if ms.resend_at == {} {
		ms.resend_budget = m.max_burst
	} else {
		elapsed := time.duration_seconds(time.tick_diff(ms.resend_at, now))
		ms.resend_budget = min(m.max_burst, ms.resend_budget + int(elapsed * f64(m.max_rate)))
	}
	ms.resend_at = now
	for bit in 0 ..< proto.NACK_SPAN {
		if n.missing & (u64(1) << uint(bit)) == 0 {
			continue
		}
		msg := cache_get(m, &sh, n.frame, n.first + bit, now)
		if msg == nil {
			continue
		}
		if ms.resend_budget < len(msg) {
			return
		}
		ms.resend_budget -= len(msg)
		media_send(m, ms, msg)
	}
}

// media_report keeps a viewer's report on the sharer it holds a lease on.
@(private = "file")
media_report :: proc(m: ^Media, ms: ^Media_Session, pt: []u8) {
	sharer, r, ok := proto.decode_report_up(pt)
	now := time.tick_now()
	if !ok || sharer == 0 || sharer != ms.watching || time.tick_diff(now, ms.watch_until) <= 0 {
		return
	}
	ms.report, ms.report_of, ms.report_at = r, sharer, now
}

/*
media_reports tells each sharer on the media link how its viewers in
its room are getting on: the worst of their fresh reports
(proto.summarize_reports). Nothing goes to a sharer nobody reports on.
*/
media_reports :: proc(m: ^Media) {
	now := time.tick_now()
	for _, target in m.sessions {
		if !target.keyed || target.superseded {
			continue
		}
		peer, known := m.peers[target.peer_key]
		if !known || !peer.sharing || peer.room == 0 {
			continue
		}
		reports := make([dynamic]proto.Video_Report, context.temp_allocator)
		for _, viewer in m.sessions {
			if viewer.report_of != peer.num ||
			   viewer.report_at == {} ||
			   time.tick_diff(viewer.report_at, now) > REPORT_FRESH {
				continue
			}
			vp, ok := m.peers[viewer.peer_key]
			if ok && vp.num == viewer.num && vp.room == peer.room {
				append(&reports, viewer.report)
			}
		}
		if len(reports) == 0 {
			continue
		}
		buf: [proto.REPORT_SIZE]u8
		media_send(m, target, proto.encode_report_down(&buf, proto.summarize_reports(reports[:])))
	}
}

@(private = "file")
media_spend :: proc(m: ^Media, num: proto.User_Num, n: int) -> bool {
	sh := media_sharer(m, num)
	now := time.tick_now()
	if sh.budget_at == {} {
		sh.budget = m.max_burst
	} else {
		elapsed := time.duration_seconds(time.tick_diff(sh.budget_at, now))
		sh.budget = min(m.max_burst, sh.budget + int(elapsed * f64(m.max_rate)))
	}
	sh.budget_at = now
	if sh.budget < n {
		return false
	}
	sh.budget -= n
	return true
}

/*
media_watch takes a viewer's lease, and passes a keyframe request on to
the sharer if the sharer is on the media link, at most once every
KEYFRAME_REQUEST_MIN.
*/
@(private = "file")
media_watch :: proc(m: ^Media, ms: ^Media_Session, viewer: Media_Peer, pt: []byte) {
	sharer, need_key := proto.decode_watch(pt)
	ms.watching = sharer
	if sharer == 0 {
		return
	}
	ms.watch_until = time.tick_add(time.tick_now(), proto.WATCH_LEASE)
	if !need_key || viewer.room == 0 {
		return
	}
	target: ^Media_Session
	for _, other in m.sessions {
		if other.keyed && !other.superseded && other.num == sharer {
			target = other
			break
		}
	}
	if target == nil {
		return // not sharing on the media link, so not sharing at all
	}
	peer, known := m.peers[target.peer_key]
	if !known || !peer.sharing || peer.room != viewer.room {
		return
	}
	sh := media_sharer(m, sharer)
	now := time.tick_now()
	if sh.last_key_sent != {} &&
	   time.tick_diff(sh.last_key_sent, now) < proto.KEYFRAME_REQUEST_MIN {
		return
	}
	sh.last_key_sent = now
	buf: [proto.KEYFRAME_SIZE]u8
	media_send(m, target, proto.encode_keyframe(&buf))
}

/*
media_housekeeping drops sessions that are silent, too old, unfinished
handshakes, and those whose connection has gone (or started over); and
forgets the budgets of those who no longer share.
*/
@(private = "file")
media_housekeeping :: proc(m: ^Media) {
	stale := make([dynamic]proto.Session_Id, context.temp_allocator)
	for idx, ms in m.sessions {
		expired: bool
		if !ms.keyed {
			expired = time.tick_since(ms.started) > proto.HANDSHAKE_TIMEOUT
		} else {
			peer, known := m.peers[ms.peer_key]
			expired =
				!known ||
				peer.num != ms.num ||
				time.tick_since(ms.last_recv) > proto.SESSION_TIMEOUT ||
				time.tick_since(ms.created) > proto.REJECT_AFTER
		}
		if expired {
			append(&stale, idx)
		}
	}
	for idx in stale {
		media_drop(m, idx)
	}
	gone := make([dynamic]proto.User_Num, context.temp_allocator)
	for num in m.sharers {
		sharing := false
		for _, peer in m.peers {
			if peer.num == num && peer.sharing {
				sharing = true
				break
			}
		}
		if !sharing {
			append(&gone, num)
		}
	}
	for num in gone {
		cache_free(&m.sharers[num])
		delete_key(&m.sharers, num)
	}
}
