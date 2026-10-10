package stress

import "core:flags"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:net"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:time"

import "common:."
import "common:proto"

/*
yap-stress: a busy server, made up. Bots (bot.odin) connect over a few
seconds, log in, and join the home channel's voice room; some of them
talk, 50 frames a second each, the way a client does. Meanwhile they
post messages, read history and search, at the rates asked for, from
bots picked at random.

Every few seconds it says how that went, as the clients see it: how
long the voice frames took to get from one bot through the server to
another (they share a clock, see bot.odin), how many went missing, and
how long requests took to be answered. Frames later than VOICE_SLACK
are about where a client starts to hear it. The server's own side is in
its log (server/loop_stats.odin): build it with
-define:YAP_LOOP_REPORT_SECONDS=10 to have it sum up as often.

It isn't part of build.sh:

	odin build src/stress -collection:common=src/common -o:speed -out:bin/yap-stress
	bin/yap-stress -bot-password:<password> -bots:100 -talkers:10 -posts:5

The bots log in as bot1, bot2...: make them first, with the server
stopped,

	yap-server account bots 50 <password> [config.json]

Their device keys are kept (in -keys), so from the second run on they
are logged in by the handshake rather than by a password.

Everything runs on one thread, which waits (poll) until a bot's socket
has something or a millisecond has gone by, so the delays it measures
include a little of its own; and if it falls behind itself, the report
says so ("this tool's loop"). Measurements go into histograms of
HIST_STEP buckets, which cost nothing much to sum up.

poll makes it a tool for Linux, macOS and the BSDs.
*/

// How long the loop waits for a packet, at most, in milliseconds.
POLL_WAIT :: 1
// About how late a voice frame can be before a client runs out of that
// speaker's audio (see server/loop_stats.odin).
VOICE_SLACK :: 20 * time.Millisecond

Options :: struct {
	server:       string `usage:"host:port of the server (default 127.0.0.1:7777)"`,
	password:     string `usage:"the server's password, if it has one"`,
	bot_password: string `usage:"the bots' password (see: yap-server account bots)"`,
	bots:         int `usage:"how many bots connect (default 20)"`,
	first:        int `usage:"the number of the first bot: bot<first> on (default 1)"`,
	keys:         string `usage:"folder for the bots' device keys (default stress-keys)"`,
	voice:        int `usage:"how many of them join the voice room (default all; -1 for none)"`,
	talkers:      int `usage:"how many of those talk (default 3)"`,
	frame:        int `usage:"bytes of a voice frame (default 80, about Opus at voice quality)"`,
	posts:        f64 `usage:"messages posted per second, all bots together (default 1)"`,
	history:      f64 `usage:"history pages read per second (default 1)"`,
	searches:     f64 `usage:"searches per second (default 0.2)"`,
	ramp:         f64 `usage:"seconds over which the bots connect (default 5)"`,
	duration:     int `usage:"seconds to run (default 60)"`,
	report:       int `usage:"seconds between reports (default 10)"`,
}

// Run is the whole test.
Run :: struct {
	opt:    Options,
	server: net.Endpoint,
	bots:   []Bot,
	stats:  Stats, // since the last report
	total:  Stats, // since the start
}

Stats :: struct {
	ready:              Hist, // how long the bots took to be ready
	frames_sent:        int,
	frames_missing:     int,
	frames:             Hist, // how long voice took through the server
	ops:                map[proto.Request_Op]Op_Stats,
	handshake_timeouts: int,
	reconnects:         int,
	loop_gap:           time.Duration, // this tool's own, the longest
}

Op_Stats :: struct {
	took:   Hist,
	failed: map[proto.Status]int,
}

// A histogram of durations, in buckets of HIST_STEP up to HIST_MOST, and
// one for everything longer.
HIST_STEP :: 100 * time.Microsecond
HIST_MOST :: 2 * time.Second
Hist :: struct {
	counts:  [HIST_MOST / HIST_STEP + 1]int,
	n:       int,
	longest: time.Duration,
}

hist_add :: proc(h: ^Hist, d: time.Duration) {
	h.counts[clamp(int(d / HIST_STEP), 0, len(h.counts) - 1)] += 1
	h.n += 1
	h.longest = max(h.longest, d)
}

hist_merge :: proc(into: ^Hist, h: ^Hist) {
	for n, i in h.counts {
		into.counts[i] += n
	}
	into.n += h.n
	into.longest = max(into.longest, h.longest)
}

// hist_over is how many took longer than `d`.
hist_over :: proc(h: ^Hist, d: time.Duration) -> (n: int) {
	for count in h.counts[int(d / HIST_STEP) + 1:] {
		n += count
	}
	return
}

// hist_at is the upper bound of the bucket the given share of them are
// in or under.
hist_at :: proc(h: ^Hist, share: f64) -> time.Duration {
	want := max(1, int(f64(h.n) * share + 0.5))
	seen := 0
	for count, i in h.counts {
		seen += count
		if seen >= want {
			return time.Duration(i + 1) * HIST_STEP
		}
	}
	return h.longest
}

// spread says how a histogram's durations went: median, 99th percentile,
// longest.
spread :: proc(h: ^Hist) -> string {
	return fmt.tprintf(
		"median %.1f ms, 99%% %.1f, longest %.1f",
		time.duration_milliseconds(hist_at(h, 0.5)),
		time.duration_milliseconds(hist_at(h, 0.99)),
		time.duration_milliseconds(h.longest),
	)
}

// Words for the messages, so that searches find some.
WORDS :: [?]string {
	"apple",
	"banana",
	"cherry",
	"delta",
	"echo",
	"falcon",
	"guitar",
	"harbor",
	"island",
	"jungle",
	"kettle",
	"lemon",
	"meadow",
	"nectar",
	"orbit",
	"pepper",
	"quartz",
	"river",
	"saddle",
	"tunnel",
	"umbrella",
	"violet",
	"walnut",
	"yonder",
	"zephyr",
}

main :: proc() {
	logger, logger_ok := common.init_logging(.info)
	if !logger_ok {
		os.exit(1)
	}
	context.logger = logger

	r := new(Run)
	r^ = {
		opt = {
			server = "127.0.0.1:7777",
			bots = 20,
			first = 1,
			keys = "stress-keys",
			talkers = 3,
			frame = 80,
			posts = 1,
			history = 1,
			searches = 0.2,
			ramp = 5,
			duration = 60,
			report = 10,
		},
	}
	flags.parse_or_exit(&r.opt, os.args, .Odin)
	opt := &r.opt
	if opt.bot_password == "" {
		fmt.eprintln("-bot-password is needed: the one given to yap-server account bots")
		os.exit(2)
	}
	if opt.voice == 0 || opt.voice > opt.bots {
		opt.voice = opt.bots
	}
	opt.voice = max(opt.voice, 0)
	opt.talkers = clamp(opt.talkers, 0, opt.voice)
	opt.report = max(opt.report, 1)

	ep, ep_ok := net.parse_endpoint(opt.server)
	if !ep_ok {
		resolved, err := net.resolve_ip4(opt.server)
		if err != nil {
			log.errorf("can't find %s: %v", opt.server, err)
			os.exit(1)
		}
		ep = resolved
	}
	if ep.port == 0 {
		ep.port = proto.DEFAULT_PORT
	}
	r.server = ep
	if !os.exists(opt.keys) {
		if err := os.make_directory(opt.keys); err != nil {
			log.errorf("can't make %s: %v", opt.keys, err)
			os.exit(1)
		}
	}

	start := time.tick_now()
	r.bots = make([]Bot, opt.bots)
	fds := make([]posix.pollfd, opt.bots)
	for &b, i in r.bots {
		b.run = r
		b.name = fmt.aprintf("bot%d", opt.first + i)
		path := fmt.tprintf("%s/%s.key", opt.keys, b.name)
		if !bot_open(&b, path) {
			os.exit(1)
		}
		b.connect_at = time.tick_add(
			start,
			time.Duration(opt.ramp * f64(time.Second) * f64(i) / f64(opt.bots)),
		)
		b.wants_voice = i < opt.voice
		b.talker = i < opt.talkers
		fds[i] = {
			fd     = posix.FD(b.sock),
			events = {.IN},
		}
	}
	log.infof(
		"%d bots to %s, %d in the voice room, %d talking; per second: %.1f posts, %.1f history, %.1f searches",
		opt.bots,
		net.to_string(r.server),
		opt.voice,
		opt.talkers,
		opt.posts,
		opt.history,
		opt.searches,
	)

	end := time.tick_add(start, time.Duration(opt.duration) * time.Second)
	next_report := time.tick_add(start, time.Duration(opt.report) * time.Second)
	last, reported := start, start
	work: [3]f64 // what's owed of posts, history and searches
	for {
		free_all(context.temp_allocator)
		now := time.tick_now()
		if gap := time.tick_diff(last, now); gap > r.stats.loop_gap {
			r.stats.loop_gap = gap
		}
		dt := time.duration_seconds(time.tick_diff(last, now))
		last = now
		for &b, i in r.bots {
			if .IN in fds[i].revents {
				bot_receive(&b)
			}
			bot_step(&b, now)
		}
		work[0] += dt * opt.posts
		work[1] += dt * opt.history
		work[2] += dt * opt.searches
		for kind in 0 ..< 3 {
			for work[kind] >= 1 {
				work[kind] -= 1
				if b := any_ready(r); b != nil {
					do_work(b, kind, now)
				}
			}
		}
		if time.tick_diff(next_report, now) >= 0 {
			report(r, time.tick_diff(start, now), false)
			reported = now
			next_report = time.tick_add(next_report, time.Duration(opt.report) * time.Second)
		}
		if time.tick_diff(end, now) >= 0 {
			break
		}
		posix.poll(raw_data(fds), posix.nfds_t(len(fds)), POLL_WAIT)
	}
	// What's left since the last report, unless that was just now.
	if time.tick_since(reported) >= time.Second {
		report(r, time.tick_since(start), false)
	}
	report(r, time.tick_since(start), true)
	for &b in r.bots {
		bot_close(&b)
	}
}

// any_ready is a bot picked at random from those that are logged in
// and know the home channel; nil if none is yet.
any_ready :: proc(r: ^Run) -> ^Bot {
	for _ in 0 ..< 8 {
		b := &r.bots[rand.int_max(len(r.bots))]
		if b.phase == .Ready && b.home != 0 {
			return b
		}
	}
	return nil
}

do_work :: proc(b: ^Bot, kind: int, now: time.Tick) {
	words := WORDS
	switch kind {
	case 0:
		sb := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&sb, "stress %s:", b.name)
		for _ in 0 ..< 3 + rand.int_max(10) {
			fmt.sbprintf(&sb, " %s", rand.choice(words[:]))
		}
		buf: [proto.MAX_CHAT_SIZE + 64]u8
		body := proto.encode_msg_post(
			buf[:],
			{conv = b.home, nonce = rand.uint64(), kind = .Text, text = strings.to_string(sb)},
		)
		bot_ask(b, .Msg_Post, body, now)
	case 1:
		buf: [proto.MSG_HISTORY_SIZE]u8
		body := proto.encode_msg_history(
			&buf,
			{conv = b.home, dir = .Before, limit = proto.MAX_HISTORY_LIMIT},
		)
		bot_ask(b, .Msg_History, body, now)
	case 2:
		buf: [proto.MSG_SEARCH_MAX_SIZE]u8
		body := proto.encode_msg_search(
			&buf,
			{query = rand.choice(words[:]), limit = proto.MAX_SEARCH_LIMIT},
		)
		bot_ask(b, .Msg_Search, body, now)
	}
}

// bot_ready: a bot has logged in and been told everything.
bot_ready :: proc(r: ^Run, b: ^Bot, took: time.Duration) {
	hist_add(&r.stats.ready, took)
}

// answered: a request's answer has come.
answered :: proc(r: ^Run, op: proto.Request_Op, status: proto.Status, took: time.Duration) {
	o := &r.stats.ops[op]
	if o == nil {
		r.stats.ops[op] = {}
		o = &r.stats.ops[op]
	}
	hist_add(&o.took, took)
	if status != .Ok {
		o.failed[status] += 1
	}
}

// frame_heard: a voice frame has come, `took` after it was sent.
frame_heard :: proc(r: ^Run, took: time.Duration) {
	hist_add(&r.stats.frames, took)
}

/*
report says how the last stretch went, and adds it to the total; with
`final`, it's the total that's said, and the window is left alone (the
caller has just reported it).
*/
report :: proc(r: ^Run, elapsed: time.Duration, final: bool) {
	s := &r.stats
	if final {
		s = &r.total
	}
	ready_now := 0
	in_voice := 0
	for &b in r.bots {
		ready_now += int(b.phase == .Ready)
		in_voice += int(b.in_voice)
	}
	sb := strings.builder_make(context.temp_allocator)
	if final {
		fmt.sbprintf(&sb, "\n== all %.0f s ==", time.duration_seconds(elapsed))
	} else {
		fmt.sbprintf(&sb, "\n== %.0f s ==", time.duration_seconds(elapsed))
	}
	fmt.sbprintf(
		&sb,
		"\nbots: %d of %d ready, %d in the voice room",
		ready_now,
		len(r.bots),
		in_voice,
	)
	if s.ready.n > 0 {
		fmt.sbprintf(&sb, "; %d got ready, in %s", s.ready.n, spread(&s.ready))
	}
	if s.handshake_timeouts > 0 || s.reconnects > 0 {
		fmt.sbprintf(
			&sb,
			"; %d handshakes timed out, %d reconnects",
			s.handshake_timeouts,
			s.reconnects,
		)
	}
	fmt.sbprintf(
		&sb,
		"\nvoice: %d frames sent, %d heard, %d missing",
		s.frames_sent,
		s.frames.n,
		s.frames_missing,
	)
	if s.frames.n > 0 {
		fmt.sbprintf(
			&sb,
			"; through the server in %s; %d over %v",
			spread(&s.frames),
			hist_over(&s.frames, VOICE_SLACK),
			VOICE_SLACK,
		)
	}
	ops, _ := slice.map_keys(s.ops, context.temp_allocator)
	slice.sort(ops)
	for op in ops {
		o := &s.ops[op]
		fmt.sbprintf(&sb, "\n%v: %d answered in %s", op, o.took.n, spread(&o.took))
		for status, n in o.failed {
			if n > 0 {
				fmt.sbprintf(&sb, "; %d %v", n, status)
			}
		}
	}
	fmt.sbprintf(
		&sb,
		"\nthis tool's loop: longest %.1f ms between looks",
		time.duration_milliseconds(s.loop_gap),
	)
	fmt.println(strings.to_string(sb))

	if final {
		return
	}
	t := &r.total
	hist_merge(&t.ready, &s.ready)
	t.frames_sent += s.frames_sent
	t.frames_missing += s.frames_missing
	hist_merge(&t.frames, &s.frames)
	for op, &o in s.ops {
		to := &t.ops[op]
		if to == nil {
			t.ops[op] = {}
			to = &t.ops[op]
		}
		hist_merge(&to.took, &o.took)
		for status, n in o.failed {
			to.failed[status] += n
		}
	}
	t.handshake_timeouts += s.handshake_timeouts
	t.reconnects += s.reconnects
	t.loop_gap = max(t.loop_gap, s.loop_gap)
	ops_map := s.ops
	clear(&ops_map)
	s^ = {
		ops = ops_map,
	}
}
