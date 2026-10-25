package server

import "core:crypto/ecdh"
import "core:log"
import "core:net"
import "core:sync"
import "core:thread"
import "core:time"

import "common:."
import "common:proto"
import "gate"

// The media link (proto.Link.Media) carries all screen sharing. It uses a UDP
// port and a thread of its own, so that the thousands of packets per second
// of a shared screen never pass through the main loop, and so that the main
// loop never delays a video frame.
//
// It also repairs packet loss. It keeps the last `cache_ms` (half a second)
// of each sharer's fragments, exactly as they were sent out. A viewer that
// finds fragments missing asks for them by number (see proto.Nack and
// video_window.odin). This costs a round trip to the server but none of the
// sharer's upload bandwidth.
//
// It also lets the bitrate of a share follow its viewers. Each viewer
// reports how well the share reaches it (see proto.Report and
// video_report.odin). Once a second each sharer is told the worst of its
// viewers' reports (see media_reports), ignoring a viewer that is far
// behind all the others.
//
// A client opens the media link once its connection is logged in, using the
// port that Server_Info names. The handshake is the same as for the bulk
// link: a hello with the connection's conn_id and link = Media, which the
// thread accepts if the device has a logged in connection with that conn_id.
// A browser connects through the relay (see relay.odin). The client sends
// its own video and its Watch leases on it, and receives the video it
// watches and the Keyframe requests for its own share. Without the media
// link there is no screen sharing, and the main loop drops any video that
// it receives.
//
// The thread only knows about the connections through a table that the main
// loop publishes whenever its state version changes (see media_sync). The
// table says who is who, in which room and whether they are sharing.
// Everything else, i.e. the sessions, leases, budgets and keyframe requests
// of the media link, belongs to the thread alone.
//
// A user can send two streams, their screen and their camera (see
// proto.Video_Stream), and everything the thread keeps about a sharer is kept
// for each stream: the budget (a camera's is `camera_rate`), the keyframe
// requests, the cache (smaller for a camera) and the reports. A session holds
// a lease on one screen and on up to MAX_CAMERAS cameras. How many cameras may
// be on in a room is the main loop's business (camera_allowed): the thread
// only passes on the camera of somebody whose Camera flag is set.
//
// A viewer's lease on a camera also says how big it shows the camera, and the
// sharer is told the largest of these and how many viewers there are in its
// room (proto.Demand): once a second with the reports, and at once when a
// lease starts or its tile changes size (media_demand). The sharer then
// encodes no bigger than that, and not at all with nobody watching.

// Media_Peer describes a connection, with what the media thread needs to know about it.
Media_Peer :: struct {
	num:      proto.User_Num,
	conn_id:  u64,
	instance: u64,
	room:     proto.Room,
	sharing:  bool,
	camera:   bool,
}

// peer_sends tells whether a peer's stream is on.
@(private = "file")
peer_sends :: proc(peer: Media_Peer, stream: proto.Video_Stream) -> bool {
	return peer.camera if stream == .Camera else peer.sharing
}

// Media_Stream names one of a sharer's streams.
Media_Stream :: struct {
	num:    proto.User_Num,
	stream: proto.Video_Stream,
}

// Media_Lease is a viewer's lease on one of a sharer's streams.
Media_Lease :: struct {
	using of:  Media_Stream, // a num of 0 for an unused one
	until:     time.Tick,
	// The viewer's last Report about it and when that arrived.
	report:    proto.Video_Report,
	report_at: time.Tick,
	// How big the viewer shows a camera, in pixels; 0 if it didn't say.
	tile:      [2]int,
}

// A session's leases: one on a screen, and one on each camera.
MEDIA_LEASES :: 1 + proto.MAX_CAMERAS

Media_Session :: struct {
	using base:    Session_Base,
	num:           proto.User_Num, // who it belongs to, once keyed
	// The streams that this session's connection is watching.
	leases:        [MEDIA_LEASES]Media_Lease,
	// How much it may have resent (Nack), similar to a sharer's budget.
	resend_budget: proto.Bucket,
}

// A Report older than this isn't counted because its viewer went quiet.
@(private = "file")
REPORT_FRESH :: 3 * time.Second

// Media_Sharer holds the budget, keyframe requests and recent fragments of one
// of a sharer's streams on the media link.
Media_Sharer :: struct {
	budget:        proto.Bucket,
	last_key_sent: time.Tick,
	cache:         ^Media_Cache, // created when the first fragment arrives
}

// Media_Cache holds a sharer's fragments exactly as they were sent out (the
// Video message that viewers get). They are stored in a ring of
// MEDIA_CACHE_SLOTS (MEDIA_CAMERA_CACHE_SLOTS for a camera, which sends far
// less) and looked up by frame and index. Fragments that are older than the
// cache age are never sent again, even if they are still in the ring.
MEDIA_CACHE_SLOTS :: 2048
MEDIA_CAMERA_CACHE_SLOTS :: 256

Media_Cached :: struct {
	key:  u64, // frame << 16 | index
	at:   time.Tick,
	size: int,
	data: [proto.MAX_PAYLOAD_SIZE]u8,
}

Media_Cache :: struct {
	slots: []Media_Cached,
	next:  int,
	index: map[u64]int, // key -> slot
}

Media :: struct {
	enabled:      bool,
	port:         int,
	max_rate:     int, // bytes per second, per sharer
	camera_rate:  int, // bytes per second, per camera
	max_burst:    int,
	// How many cameras may be on in a channel's room. Only used by the main
	// loop (camera_allowed).
	max_cameras:  int,
	max_sessions: int,
	gate:         gate.Gate, // which Inits may start a session
	cache_age:    time.Duration, // how long fragments are kept for Nacks
	password:     string, // the server's password
	key:          ecdh.Private_Key, // a copy of the server's key for the thread
	sock:         net.UDP_Socket,
	thread:       ^thread.Thread,
	stop:         bool, // atomic

	// Written by the main loop and read by the thread, guarded by `mutex`.
	mutex:        sync.Mutex,
	peers:        map[[proto.KEY_SIZE]byte]Media_Peer,

	// Only used by the main loop: what it published last.
	published:    u32,
	published_at: time.Tick,

	// Only used by the media thread.
	sessions:     map[proto.Session_Id]^Media_Session,
	sharers:      map[Media_Stream]Media_Sharer,
	housekept:    time.Tick,
}

// How often the main loop publishes even when its version hasn't changed,
// and how often the thread looks for sessions to drop.
@(private = "file")
MEDIA_HOUSEKEEPING :: 1 * time.Second
// How long the thread waits for a packet before it continues with its loop anyway.
@(private = "file")
MEDIA_WAIT :: 100 * time.Millisecond

// media_port returns the media link's port from `settings`, or 0 if the media link is disabled.
media_port :: proc(settings: Settings) -> int {
	cfg := settings.video
	if !cfg.enabled {
		return 0
	}
	return cfg.port if cfg.port != 0 else settings.port + 1
}

// media_open opens the media link's port and starts its thread, if the
// config enables it. If it is disabled or the port can't be opened, desktop
// clients share their screens over their bulk links instead.
media_open :: proc(s: ^Server, settings: Settings) {
	m := &s.media
	cfg := settings.video
	if !cfg.enabled {
		log.info("the media link is disabled, so screen sharing over it is unavailable")
		return
	}
	m.port = media_port(settings)
	m.max_rate = cfg.max_kbit * 1000 / 8
	m.camera_rate = cfg.camera_max_kbit * 1000 / 8
	m.max_cameras = cfg.max_cameras
	m.max_burst = proto.MAX_VIDEO_FRAME_SIZE + 64 * 1024
	m.max_sessions = s.max_sessions
	m.cache_age = time.Duration(cfg.cache_ms) * time.Millisecond
	m.password = s.password
	m.key = s.key
	sock, err := net.make_bound_udp_socket(net.IP4_Any, m.port)
	if err != nil {
		log.errorf(
			"the media link can't use udp port %d (%v), so screen sharing over it is unavailable",
			m.port,
			err,
		)
		return
	}
	m.sock = sock
	net.set_option(sock, .Receive_Timeout, MEDIA_WAIT)
	// A keyframe arrives as hundreds of packets at once, so the buffers must be large.
	net.set_option(sock, .Receive_Buffer_Size, 8 * 1024 * 1024)
	net.set_option(sock, .Send_Buffer_Size, 8 * 1024 * 1024)
	m.enabled = true
	media_publish(s)
	m.thread = thread.create_and_start_with_poly_data(m, media_run, init_context = context)
	log.infof(
		"media link on udp :%d, %d kbit/s per sharer, %d cameras per channel at %d kbit/s",
		m.port,
		cfg.max_kbit,
		cfg.max_cameras,
		cfg.camera_max_kbit,
	)
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

// media_free frees what the thread allocated.
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
	gate.destroy(&m.gate)
}

@(private = "file")
cache_free :: proc(sh: ^Media_Sharer) {
	if sh.cache != nil {
		delete(sh.cache.index)
		delete(sh.cache.slots)
		free(sh.cache)
		sh.cache = nil
	}
}

// media_sync publishes the connections to the thread when anything that
// clients can see has changed (the state version), and every second
// regardless. It is a sync phase of the main loop.
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
	// Only connections that are logged in and visible are published. The
	// others may only log in.
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
			camera   = .Camera in u.flags,
		}
	}
	m.published = s.version
	m.published_at = time.tick_now()
}

// media_run is the main procedure of the media thread.
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

// media_handle_packet handles one packet received on the media port.
// `m.mutex` must be held.
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
	session_init(m.sock, &m.key, &m.gate, &m.sessions, m.max_sessions, packet, from)
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
		// The Welcome was lost, so send it again to the address we know.
		if session_rewelcome_due(ms) {
			media_welcome(m, ms, peer.instance)
		}
		return
	}
	conn_id, link, result := session_finish(ms, &m.gate, m.password, packet, from)
	switch {
	case result == .Invalid:
		media_drop(m, idx)
		return
	case result == .Wrong_Password:
		media_refuse(m, ms, from, .Wrong_Password)
		return
	case result == .Version || link != .Media:
		media_refuse(m, ms, from, .Version)
		return
	}
	peer, known = m.peers[ms.peer_key]
	if !known || peer.conn_id != conn_id {
		media_refuse(m, ms, from, .No_Connection)
		return
	}
	session_keyed(ms, &m.gate, from)
	ms.num = peer.num
	for _, other in m.sessions {
		if other != ms && other.keyed && other.peer_key == ms.peer_key {
			other.superseded = true
		}
	}
	log.debugf("media: %08x has a new media link", common.key_id(ms.peer_key))
	media_welcome(m, ms, peer.instance)
}

@(private = "file")
media_welcome :: proc(m: ^Media, ms: ^Media_Session, instance: u64) {
	buf: [proto.WELCOME_SIZE]u8
	msg := proto.encode_welcome(&buf, instance, true)
	for _ in 0 ..< WELCOME_COPIES {
		media_send(m, ms, msg)
	}
}

@(private = "file")
media_refuse :: proc(m: ^Media, ms: ^Media_Session, from: net.Endpoint, reason: proto.Refusal) {
	log.debugf("media: refused %08x: %v", common.key_id(ms.peer_key), reason)
	session_refuse(m.sock, ms, from, reason)
	media_drop(m, ms.local_idx)
}

@(private = "file")
media_send :: proc(m: ^Media, ms: ^Media_Session, msg: []byte) {
	session_send(m.sock, ms, msg, ms.endpoint)
}

@(private = "file")
media_drop :: proc(m: ^Media, idx: proto.Session_Id) {
	if ms := m.sessions[idx] or_else nil; ms != nil {
		delete_key(&m.sessions, idx)
		session_release(&m.gate, ms)
		free(ms)
	}
}

@(private = "file")
media_data :: proc(m: ^Media, packet: []byte, from: net.Endpoint) {
	idx := proto.receiver_index(packet)
	ms := m.sessions[idx] or_else nil
	if ms == nil || !ms.keyed {
		return
	}
	// A media session is made for a logged in connection, so it follows the
	// client to a new address as long as that connection is there.
	peer, known := m.peers[ms.peer_key]
	if !known || peer.num != ms.num {
		return // the peer is gone or logged out, housekeeping drops the session
	}
	pt_buf: [proto.MAX_PACKET_SIZE]byte
	pt, ok := session_receive(ms, packet, from, pt_buf[:], follow = true)
	if !ok {
		return
	}
	if session_confirm(ms) {
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
	kind, kind_ok := proto.message_kind(pt)
	if !kind_ok {
		return // a keepalive
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

// media_relay forwards a fragment to every media session that holds a lease on
// its stream in the sharer's room, encrypted separately for each. Video from
// somebody whose stream isn't on or who is over their budget is dropped.
@(private = "file")
media_relay :: proc(m: ^Media, from: ^Media_Session, peer: Media_Peer, pt: []byte) {
	f, ok := proto.decode_video_up(pt)
	if !ok || !peer_sends(peer, f.stream) || peer.room == 0 {
		return
	}
	of := Media_Stream{peer.num, f.stream}
	if !media_spend(m, of, len(pt)) {
		log.debugf("media: %d is sending %v faster than the server passes on", peer.num, f.stream)
		return
	}
	out_buf: [proto.MAX_PAYLOAD_SIZE]u8
	msg := proto.video_up_to_down(&out_buf, peer.num, pt)
	now := time.tick_now()
	if m.cache_age > 0 {
		cache_put(media_sharer(m, of), of.stream, f.frame, f.index, msg, now)
	}
	for _, ms in m.sessions {
		if !ms.keyed || ms.superseded || ms == from || lease_find(ms, of, now) == nil {
			continue
		}
		viewer, known := m.peers[ms.peer_key]
		if !known || viewer.room != peer.room || viewer.num == peer.num {
			continue
		}
		media_send(m, ms, msg)
	}
}

// lease_find returns the session's lease on a stream if it hasn't run out,
// or nil.
@(private = "file")
lease_find :: proc(ms: ^Media_Session, of: Media_Stream, now: time.Tick) -> ^Media_Lease {
	for &l in ms.leases {
		if l.of == of && time.tick_diff(now, l.until) > 0 {
			return &l
		}
	}
	return nil
}

// lease_take returns the session's lease on a stream, taking a new one if it
// has none. A lease on a screen replaces the one on another screen. Nil if the
// session already holds as many leases on cameras as it may.
@(private = "file")
lease_take :: proc(ms: ^Media_Session, of: Media_Stream, now: time.Tick) -> ^Media_Lease {
	free_lease: ^Media_Lease
	cameras := 0
	for &l in ms.leases {
		switch {
		case l.of == of:
			return &l
		case l.num != 0 && l.stream == .Screen && of.stream == .Screen:
			l = {
				of = of,
			}
			return &l
		case l.num == 0 || time.tick_diff(now, l.until) <= 0:
			if free_lease == nil {
				free_lease = &l
			}
		case l.stream == .Camera:
			cameras += 1
		}
	}
	if free_lease == nil || (of.stream == .Camera && cameras >= proto.MAX_CAMERAS) {
		return nil
	}
	free_lease^ = {
		of = of,
	}
	return free_lease
}

// media_sharer returns what the thread keeps for a sharer's stream, creating it if necessary.
@(private = "file")
media_sharer :: proc(m: ^Media, of: Media_Stream) -> ^Media_Sharer {
	sh := &m.sharers[of]
	if sh == nil {
		m.sharers[of] = {}
		sh = &m.sharers[of]
	}
	return sh
}

@(private = "file")
cache_put :: proc(
	sh: ^Media_Sharer,
	stream: proto.Video_Stream,
	frame: u32,
	index: int,
	msg: []u8,
	now: time.Tick,
) {
	if sh.cache == nil {
		sh.cache = new(Media_Cache)
		slots := MEDIA_CAMERA_CACHE_SLOTS if stream == .Camera else MEDIA_CACHE_SLOTS
		sh.cache.slots = make([]Media_Cached, slots)
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
	c.next = (c.next + 1) % len(c.slots)
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

// media_nack resends the fragments of a frame that a viewer asks for from a
// stream it is watching. They are taken from the cache, as far as the viewer's
// own budget (the sharer's rate) allows, so that a viewer can't make the server
// send more than the sharer could.
@(private = "file")
media_nack :: proc(m: ^Media, ms: ^Media_Session, viewer: Media_Peer, pt: []u8) {
	sharer, n, stream, ok := proto.decode_nack(pt)
	of := Media_Stream{sharer, stream}
	now := time.tick_now()
	if !ok || sharer == 0 || lease_find(ms, of, now) == nil {
		return
	}
	// A lease can be taken on anyone (media_watch), so the room is checked
	// here as media_relay does: only viewers in the sharer's room get its
	// fragments.
	if !media_same_room(m, viewer, of) {
		return
	}
	sh := m.sharers[of] or_else {}
	if sh.cache == nil {
		return
	}
	proto.bucket_refill(&ms.resend_budget, now, f64(m.max_rate), f64(m.max_burst))
	for bit in 0 ..< proto.NACK_SPAN {
		if n.missing & (u64(1) << uint(bit)) == 0 {
			continue
		}
		msg := cache_get(m, &sh, n.frame, n.first + bit, now)
		if msg == nil {
			continue
		}
		if !proto.bucket_take(&ms.resend_budget, f64(len(msg))) {
			return
		}
		media_send(m, ms, msg)
	}
}

// media_same_room tells whether a sharer's stream is on in the viewer's room.
@(private = "file")
media_same_room :: proc(m: ^Media, viewer: Media_Peer, of: Media_Stream) -> bool {
	if viewer.room == 0 || viewer.num == of.num {
		return false
	}
	// A user can be connected from more than one device.
	for _, peer in m.peers {
		if peer.num == of.num && peer_sends(peer, of.stream) && peer.room == viewer.room {
			return true
		}
	}
	return false
}

// media_report stores a viewer's report about a stream it holds a lease on.
@(private = "file")
media_report :: proc(m: ^Media, ms: ^Media_Session, pt: []u8) {
	sharer, r, stream, ok := proto.decode_report_up(pt)
	now := time.tick_now()
	if !ok || sharer == 0 {
		return
	}
	if l := lease_find(ms, {sharer, stream}, now); l != nil {
		l.report, l.report_at = r, now
	}
}

// media_reports tells each sharer on the media link how well each of its
// streams reaches its viewers in its room. It sends the worst of their recent
// reports (see proto.summarize_reports). Streams that have no reports are sent
// nothing.
media_reports :: proc(m: ^Media) {
	now := time.tick_now()
	for _, target in m.sessions {
		if !target.keyed || target.superseded {
			continue
		}
		peer, known := m.peers[target.peer_key]
		if !known || peer.room == 0 {
			continue
		}
		for stream in proto.Video_Stream {
			if !peer_sends(peer, stream) {
				continue
			}
			of := Media_Stream{peer.num, stream}
			reports := make([dynamic]proto.Video_Report, context.temp_allocator)
			for _, viewer in m.sessions {
				vp, ok := m.peers[viewer.peer_key]
				if !ok || vp.num != viewer.num || vp.room != peer.room {
					continue
				}
				for l in viewer.leases {
					if l.of == of &&
					   l.report_at != {} &&
					   time.tick_diff(l.report_at, now) <= REPORT_FRESH {
						append(&reports, l.report)
					}
				}
			}
			if stream == .Camera {
				media_send_demand(m, target, peer, now)
			}
			if len(reports) == 0 {
				continue
			}
			buf: [proto.REPORT_CAMERA_SIZE]u8
			summary := proto.summarize_reports(reports[:])
			media_send(m, target, proto.encode_report_down(&buf, summary, stream))
		}
	}
}

// media_demand works out what the viewers of a camera in the sharer's room
// want of it: the largest tile they show it at (none if one of them didn't
// say), and how many they are.
media_demand :: proc(m: ^Media, sharer: Media_Peer, now: time.Tick) -> (d: proto.Demand) {
	d.stream = .Camera
	of := Media_Stream{sharer.num, .Camera}
	unsized := false
	for _, viewer in m.sessions {
		if !viewer.keyed || viewer.superseded {
			continue
		}
		vp, ok := m.peers[viewer.peer_key]
		if !ok || vp.num != viewer.num || vp.room != sharer.room || vp.num == sharer.num {
			continue
		}
		l := lease_find(viewer, of, now)
		if l == nil {
			continue
		}
		d.viewers += 1
		if l.tile.x <= 0 || l.tile.y <= 0 {
			unsized = true
		}
		d.tile = {max(d.tile.x, l.tile.x), max(d.tile.y, l.tile.y)}
	}
	if unsized {
		d.tile = {}
	}
	return
}

@(private = "file")
media_send_demand :: proc(m: ^Media, target: ^Media_Session, sharer: Media_Peer, now: time.Tick) {
	buf: [proto.DEMAND_SIZE]u8
	media_send(m, target, proto.encode_demand(&buf, media_demand(m, sharer, now)))
}

// media_sharer_session returns the media session of the user `num` whose
// stream `stream` is on, and that user's peer; nil if there's none.
@(private = "file")
media_sharer_session :: proc(
	m: ^Media,
	num: proto.User_Num,
	stream: proto.Video_Stream,
) -> (
	^Media_Session,
	Media_Peer,
) {
	for _, other in m.sessions {
		if !other.keyed || other.superseded || other.num != num {
			continue
		}
		peer, known := m.peers[other.peer_key]
		if known && peer.num == num && peer_sends(peer, stream) {
			return other, peer
		}
	}
	return nil, {}
}

@(private = "file")
media_spend :: proc(m: ^Media, of: Media_Stream, n: int) -> bool {
	sh := media_sharer(m, of)
	rate := m.camera_rate if of.stream == .Camera else m.max_rate
	proto.bucket_refill(&sh.budget, time.tick_now(), f64(rate), f64(m.max_burst))
	return proto.bucket_take(&sh.budget, f64(n))
}

// media_watch records a viewer's lease, or ends it, and forwards a keyframe
// request to the sharer if the sharer is on the media link, at most once every
// KEYFRAME_REQUEST_MIN for each stream.
@(private = "file")
media_watch :: proc(m: ^Media, ms: ^Media_Session, viewer: Media_Peer, pt: []byte) {
	w := proto.decode_watch(pt)
	of := Media_Stream{w.sharer, w.stream}
	now := time.tick_now()
	if w.sharer == 0 || w.stop {
		for &l in ms.leases {
			if l.of == of || (w.sharer == 0 && l.stream == w.stream) {
				l = {}
			}
		}
		return
	}
	l := lease_take(ms, of, now)
	if l == nil {
		return
	}
	fresh := time.tick_diff(now, l.until) <= 0
	resized := w.stream == .Camera && w.tile != l.tile
	l.until = time.tick_add(now, proto.WATCH_LEASE)
	l.tile = w.tile if w.stream == .Camera else {}
	if viewer.room == 0 || (!w.need_key && !(w.stream == .Camera && (fresh || resized))) {
		return
	}
	target, peer := media_sharer_session(m, w.sharer, w.stream)
	if target == nil || peer.room != viewer.room {
		return // the sharer isn't on the media link, so isn't sharing at all
	}
	// A new viewer, or one whose tile changed, is told to the sharer at once.
	if w.stream == .Camera && (fresh || resized) {
		media_send_demand(m, target, peer, now)
	}
	if !w.need_key {
		return
	}
	sh := media_sharer(m, of)
	if sh.last_key_sent != {} &&
	   time.tick_diff(sh.last_key_sent, now) < proto.KEYFRAME_REQUEST_MIN {
		return
	}
	sh.last_key_sent = now
	buf: [proto.KEYFRAME_CAMERA_SIZE]u8
	media_send(m, target, proto.encode_keyframe(&buf, w.stream))
}

// media_housekeeping drops sessions that are silent, too old, have an
// unfinished handshake, or whose connection has gone or started over. It
// also forgets the budgets of streams that are no longer on.
media_housekeeping :: proc(m: ^Media) {
	stale := make([dynamic]proto.Session_Id, context.temp_allocator)
	for idx, ms in m.sessions {
		expired := session_expired(ms)
		if ms.keyed && !expired {
			peer, known := m.peers[ms.peer_key]
			expired = !known || peer.num != ms.num
		}
		if expired {
			append(&stale, idx)
		}
	}
	for idx in stale {
		media_drop(m, idx)
	}
	gone := make([dynamic]Media_Stream, context.temp_allocator)
	for of in m.sharers {
		on := false
		for _, peer in m.peers {
			if peer.num == of.num && peer_sends(peer, of.stream) {
				on = true
				break
			}
		}
		if !on {
			append(&gone, of)
		}
	}
	for of in gone {
		cache_free(&m.sharers[of])
		delete_key(&m.sharers, of)
	}
}
