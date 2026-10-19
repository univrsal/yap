/*
Sharing, the part that's the same on every platform: a thread that
waits for captures (pipeline.h), encodes at most `fps` of them a second,
and queues the packets for yv_share_pull.

A still screen captures nothing new and so encodes nothing, which costs
nothing; a keyframe asked for in the meantime is made from the last
capture again. When the source changes size, the encoder is made again
for the new size, which starts with a keyframe. When the viewers can't
decode what's encoded (yv_share_set_codecs), another encoder takes over,
also from a keyframe.

Low latency over everything: no B-frames, no lookahead, one frame in
flight, keyframes when asked for (and every ten seconds, in case). The
rate is VBR with a peak of 1.5 times the bitrate and half a second of
buffer, so a keyframe of a detailed screen isn't starved; the client
paces what goes out, and changes the bitrate as its viewers' reports
say (yv_share_set_bitrate).
*/
#include "pipeline.h"

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <deque>
#include <thread>

#include "ffmpeg.h"

namespace yv {

namespace {

// Encoded frames waiting to be pulled; more means nobody is pulling.
constexpr size_t MAX_QUEUED = 8;
// A keyframe this often whatever happens.
constexpr int KEY_SECONDS = 10;
// A new bitrate costs a keyframe whatever the encoder (FFmpeg's NVENC
// forces one as it reconfigures; the others start again), so it's only
// taken up for this big a change, and this seldom.
constexpr double BITRATE_CHANGE = 0.2;
constexpr uint64_t BITRATE_US = 3'000'000;
// The most an encoder that can be held to it may make of one frame, in
// bits: well below the 1 MB a client sends at most of a frame, which
// drops anything bigger and asks for a keyframe, which may be as big.
constexpr int MAX_FRAME_BITS = 6'000'000;

struct Encoded {
	std::vector<uint8_t> data;
	uint64_t pts_us;
	yv_codec codec;
	bool key;
};

bool starts_with(const char *s, const char *prefix) {
	return strncmp(s, prefix, strlen(prefix)) == 0;
}

yv_codec codec_of(const char *encoder) {
	if (starts_with(encoder, "av1_")) {
		return YV_CODEC_AV1;
	}
	if (starts_with(encoder, "hevc_")) {
		return YV_CODEC_HEVC;
	}
	return YV_CODEC_H264;
}

// Fits w x h into max_w x max_h keeping its shape, in even numbers,
// which NV12 needs.
void fit(int w, int h, int max_w, int max_h, int &out_w, int &out_h) {
	double s = 1.0;
	if (max_w > 0 && w > max_w) {
		s = std::min(s, static_cast<double>(max_w) / w);
	}
	if (max_h > 0 && h > max_h) {
		s = std::min(s, static_cast<double>(max_h) / h);
	}
	out_w = std::max(2, static_cast<int>(w * s) & ~1);
	out_h = std::max(2, static_cast<int>(h * s) & ~1);
}

/*
Parameter_Sets keeps the latest parameter sets (H.264's SPS and PPS,
HEVC's VPS too, AV1's sequence header) seen in the encoder's output, and
puts them in front of any keyframe that came without them: a viewer can
only start from a keyframe that has them. Most encoders repeat them by
themselves when there are no global headers; this makes sure.
*/
class Parameter_Sets {
public:
	explicit Parameter_Sets(yv_codec codec) : codec_(codec) {}

	void fix(std::vector<uint8_t> &pkt, bool key) {
		std::vector<uint8_t> found;
		bool has = scan(pkt, found);
		if (!found.empty()) {
			sets_ = std::move(found);
		}
		if (key && !has && !sets_.empty()) {
			if (codec_ == YV_CODEC_AV1) {
				// After the temporal delimiter, if there is one.
				size_t at = (pkt.size() >= 2 && ((pkt[0] >> 3) & 0xf) == 2) ? 2 : 0;
				pkt.insert(pkt.begin() + at, sets_.begin(), sets_.end());
			} else {
				pkt.insert(pkt.begin(), sets_.begin(), sets_.end());
			}
		}
	}

private:
	yv_codec codec_;
	std::vector<uint8_t> sets_;

	// scan collects the packet's parameter sets into `found` and says
	// whether it has a full set.
	bool scan(const std::vector<uint8_t> &p, std::vector<uint8_t> &found) {
		if (codec_ == YV_CODEC_AV1) {
			size_t pos = 0;
			while (pos < p.size()) {
				size_t start = pos;
				uint8_t h = p[pos++];
				if (h & 0x04) {
					pos++;
				}
				if (!(h & 0x02)) {
					return false; // no sizes; can't walk it
				}
				uint64_t size = 0;
				for (int i = 0; i < 8 && pos < p.size(); i++) {
					uint8_t b = p[pos++];
					size |= static_cast<uint64_t>(b & 0x7f) << (7 * i);
					if (!(b & 0x80)) {
						break;
					}
				}
				pos += size;
				if (pos > p.size()) {
					return false;
				}
				if (((h >> 3) & 0xf) == 1) { // sequence header
					found.assign(p.begin() + start, p.begin() + pos);
					return true;
				}
			}
			return false;
		}
		bool hevc = codec_ == YV_CODEC_HEVC;
		bool sps = false, pps = false, vps = !hevc;
		// NAL units by their start codes.
		std::vector<size_t> starts;
		for (size_t i = 0; i + 3 <= p.size(); i++) {
			if (p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1) {
				starts.push_back((i > 0 && p[i - 1] == 0) ? i - 1 : i);
				i += 2;
			}
		}
		for (size_t n = 0; n < starts.size(); n++) {
			size_t start = starts[n];
			size_t end = n + 1 < starts.size() ? starts[n + 1] : p.size();
			size_t hdr = start + (p[start + 2] == 1 ? 3 : 4);
			if (hdr >= end) {
				continue;
			}
			int type = hevc ? (p[hdr] >> 1) & 0x3f : p[hdr] & 0x1f;
			bool set = hevc ? (type == 32 || type == 33 || type == 34) : (type == 7 || type == 8);
			if (set) {
				found.insert(found.end(), p.begin() + start, p.begin() + end);
				vps = vps || type == 32;
				sps = sps || type == (hevc ? 33 : 7);
				pps = pps || type == (hevc ? 34 : 8);
			}
		}
		if (!(sps && pps && vps)) {
			found.clear();
			return false;
		}
		return true;
	}
};

// Whether FFmpeg's `name` takes a new bit_rate as it goes (NVENC
// reconfigures, Quick Sync resets); the others only read it on opening.
bool live_bitrate(const char *name) {
	return strstr(name, "_nvenc") || strstr(name, "_qsv");
}

/*
Whether FFmpeg's `name` says "not yet" while the frame it was just given
is still being encoded, rather than waiting for it. AMF's do: each look
waits about a millisecond in the driver, so encode looks until there's a
packet (and, with AV_CODEC_FLAG_LOW_DELAY, they look at all before the
next frame; without it a packet only came out with the next frame).
*/
bool polls_output(const char *name) {
	return strstr(name, "_amf") != nullptr;
}

/*
Low latency settings, per encoder family; any an encoder doesn't know
are left over in the dictionary and ignored.
*/
void encoder_options(const char *name, AVDictionary **opts) {
	if (strstr(name, "_nvenc")) {
		av_dict_set(opts, "preset", "p4", 0);
		av_dict_set(opts, "tune", "ll", 0);
		av_dict_set(opts, "zerolatency", "1", 0);
		av_dict_set(opts, "delay", "0", 0);
		av_dict_set(opts, "rc", "vbr", 0);
		av_dict_set(opts, "forced-idr", "1", 0);
	} else if (strstr(name, "_amf")) {
		av_dict_set(opts, "usage", "ultralowlatency", 0);
		av_dict_set(opts, "quality", "balanced", 0);
		av_dict_set(opts, "rc", "vbr_peak", 0);
		// Without it a requested keyframe is an I frame that isn't an IDR,
		// which isn't flagged as a keyframe either, so it doesn't count:
		// a viewer then only gets going at the next restart or GOP.
		av_dict_set(opts, "forced_idr", "1", 0);
		// Without these AMF ignores rc_buffer_size for keyframes, which
		// then come out at more than a second's worth of the bitrate.
		av_dict_set(opts, "enforce_hrd", "1", 0);
		av_dict_set_int(opts, "max_au_size", MAX_FRAME_BITS, 0);
	} else if (strstr(name, "_qsv")) {
		av_dict_set(opts, "preset", "veryfast", 0);
		av_dict_set(opts, "async_depth", "1", 0);
		av_dict_set(opts, "look_ahead", "0", 0);
		av_dict_set(opts, "forced_idr", "1", 0);
	} else if (strstr(name, "_vaapi")) {
		av_dict_set(opts, "async_depth", "1", 0);
	} else if (strstr(name, "_videotoolbox")) {
		av_dict_set(opts, "realtime", "1", 0);
		av_dict_set(opts, "prio_speed", "1", 0);
	} else if (strcmp(name, "libopenh264") == 0) {
		// Its default aims at a quality, not the bitrate it's given; and
		// FFmpeg's default profile is one it doesn't take (it says so).
		av_dict_set(opts, "rc_mode", "bitrate", 0);
		av_dict_set(opts, "profile", "high", 0);
	}
}

} // namespace

} // namespace yv

struct yv_share {
	yv_context *ctx = nullptr;
	yv_share_config config{};
	std::thread thread;
	std::atomic<bool> stop{false};
	std::atomic<bool> want_key{true};
	std::atomic<uint32_t> want_kbit{0}; // yv_share_set_bitrate's; 0 for none
	std::atomic<uint32_t> encoding_kbit{0}; // `kbit`, for yv_share_get_bitrate
	std::atomic<uint32_t> want_codecs{0}; // yv_share_set_codecs's; 0 for any
	std::atomic<int> state{YV_SHARE_STARTING};
	std::string error; // set before state becomes Failed

	std::mutex mutex;
	std::deque<yv::Encoded> queue;
	yv::Encoded pulled; // what the last yv_share_pull handed out

	// The thread's own.
	std::string encoder_name;
	yv_codec codec = YV_CODEC_H264;
	uint32_t codecs = 0; // the want_codecs the encoder was picked for
	AVCodecContext *enc = nullptr;
	AVBufferRef *frames = nullptr;
	int enc_w = 0, enc_h = 0;
	uint32_t kbit = 0;        // what the encoder is set to
	uint64_t rate_at = 0;     // when the bitrate last changed
	AVFrame *frame = nullptr;
	AVFrame *planar = nullptr; // frame as YUV420P, for encoders that want that
	AVPacket *pkt = nullptr;
};

namespace yv {

namespace {

void fail(yv_share *s, const std::string &why) {
	log(YV_LOG_ERROR, "share: %s", why.c_str());
	s->error = why;
	s->state.store(YV_SHARE_FAILED);
}

/*
close_encoder drains the encoder before freeing it, dropping what comes
out. FFmpeg's AMF encoders keep a reference to each frame they're given
until its packet comes back, and closing without draining leaks those
(and so the frames' pool, its device and the whole capture device, some
100 MB at 4K, at every stop or restart).
*/
void close_encoder(yv_share *s) {
	if (s->enc && avcodec_is_open(s->enc) && avcodec_send_frame(s->enc, nullptr) >= 0) {
		AVPacket *pkt = av_packet_alloc();
		while (pkt && avcodec_receive_packet(s->enc, pkt) >= 0) {
			av_packet_unref(pkt);
		}
		av_packet_free(&pkt);
	}
	avcodec_free_context(&s->enc);
	av_buffer_unref(&s->frames);
	s->enc_w = s->enc_h = 0;
}

bool open_encoder(yv_share *s, Pipeline &pipe, int w, int h) {
	close_encoder(s);
	const AVCodec *codec = avcodec_find_encoder_by_name(s->encoder_name.c_str());
	if (!codec) {
		return false;
	}
	s->enc = avcodec_alloc_context3(codec);
	AVCodecContext *e = s->enc;
	int fps = s->config.fps;
	int64_t rate = static_cast<int64_t>(s->kbit) * 1000;
	e->width = w;
	e->height = h;
	e->time_base = {1, 1000000}; // pts are microseconds
	e->framerate = {fps, 1};
	e->gop_size = fps * KEY_SECONDS;
	e->max_b_frames = 0;
	// One frame in, its packet out (AMF, VideoToolbox; the others are
	// told in encoder_options).
	e->flags |= AV_CODEC_FLAG_LOW_DELAY;
	e->bit_rate = rate;
	e->rc_max_rate = rate * 3 / 2;
	e->rc_buffer_size = static_cast<int>(rate / 2);
	e->colorspace = AVCOL_SPC_BT709;
	e->color_primaries = AVCOL_PRI_BT709;
	e->color_trc = AVCOL_TRC_BT709;
	e->color_range = AVCOL_RANGE_MPEG;
	// 0 is as many as there are cores, for an encoder that has its own
	// threads (OpenH264); the hardware ones ignore it.
	e->thread_count = 0;

	// GPU frames where the encoder takes them, so the picture never
	// leaves the GPU; frames in memory otherwise. An encoder that takes
	// nothing else (VA-API's) gets them even when YAP_VIDEO_SOFTWARE
	// says memory.
	AVBufferRef *device = pipe.hw_device();
	if (device && (!software_only() || !takes_pix_fmt(codec, AV_PIX_FMT_NV12))) {
		s->frames = pipe.hw_frames(w, h);
		if (s->frames &&
		    !takes_pix_fmt(codec, reinterpret_cast<AVHWFramesContext *>(s->frames->data)->format)) {
			av_buffer_unref(&s->frames);
		}
	}
	av_buffer_unref(&device);
	if (s->frames) {
		e->pix_fmt = static_cast<AVPixelFormat>(
			reinterpret_cast<AVHWFramesContext *>(s->frames->data)->format);
		e->hw_frames_ctx = av_buffer_ref(s->frames);
	} else {
		// convert makes NV12, which encode turns into YUV420P for an
		// encoder that takes nothing else.
		e->pix_fmt = takes_pix_fmt(codec, AV_PIX_FMT_NV12) ? AV_PIX_FMT_NV12 : AV_PIX_FMT_YUV420P;
	}
	AVDictionary *opts = nullptr;
	encoder_options(s->encoder_name.c_str(), &opts);
	int err = avcodec_open2(e, codec, &opts);
	av_dict_free(&opts);
	if (err < 0) {
		char msg[128];
		av_strerror(err, msg, sizeof(msg));
		log(YV_LOG_ERROR, "share: %s won't open at %dx%d: %s", s->encoder_name.c_str(), w, h, msg);
		close_encoder(s);
		return false;
	}
	s->enc_w = w;
	s->enc_h = h;
	log(YV_LOG_INFO, "share: encoding %dx%d at %d fps, %u kbit/s with %s%s", w, h, fps, s->kbit,
	    s->encoder_name.c_str(), s->frames ? " from the GPU" : " from memory");
	return true;
}

// queue adds a packet for yv_share_pull, or drops everything waiting
// if nobody's pulling.
void queue(yv_share *s, Encoded &&e) {
	std::lock_guard<std::mutex> lock(s->mutex);
	if (s->queue.size() >= MAX_QUEUED) {
		s->queue.clear();
		s->want_key.store(true);
		if (!e.key) {
			return;
		}
	}
	s->queue.push_back(std::move(e));
}

uint64_t now_us();
void follow_codecs(yv_share *s, Parameter_Sets &sets);

/*
follow_bitrate takes up yv_share_set_bitrate's bitrate, if it's changed
enough and it's been a while: straight into an encoder that changes as
it goes, else by starting it again (closing it here; encode opens it).
*/
void follow_bitrate(yv_share *s) {
	uint32_t want = s->want_kbit.load();
	if (want == 0 || want == s->kbit || !s->enc) {
		return;
	}
	double change = std::abs(static_cast<double>(want) - s->kbit) / s->kbit;
	// Back to the configured bitrate always counts, else it might never get there.
	bool back = want == s->config.kbit;
	uint64_t now = now_us();
	if ((change < BITRATE_CHANGE && !back) || (s->rate_at && now - s->rate_at < BITRATE_US)) {
		return;
	}
	s->rate_at = now;
	if (live_bitrate(s->encoder_name.c_str())) {
		int64_t rate = static_cast<int64_t>(want) * 1000;
		s->enc->bit_rate = rate;
		s->enc->rc_max_rate = rate * 3 / 2;
		s->enc->rc_buffer_size = static_cast<int>(rate / 2);
		log(YV_LOG_INFO, "share: bitrate %u -> %u kbit/s", s->kbit, want);
		s->kbit = want;
		s->encoding_kbit.store(want);
		return;
	}
	log(YV_LOG_INFO, "share: bitrate %u -> %u kbit/s, starting %s again", s->kbit, want,
	    s->encoder_name.c_str());
	s->kbit = want;
	s->encoding_kbit.store(want);
	close_encoder(s);
}

bool encode(yv_share *s, Pipeline &pipe, Parameter_Sets &sets, uint64_t pts) {
	follow_codecs(s, sets);
	follow_bitrate(s);
	int w, h;
	fit(pipe.width(), pipe.height(), s->config.max_width, s->config.max_height, w, h);
	if (!s->enc || w != s->enc_w || h != s->enc_h) {
		if (!open_encoder(s, pipe, w, h)) {
			fail(s, "the encoder (" + s->encoder_name + ") won't start");
			return false;
		}
		s->want_key.store(true);
	}
	av_frame_unref(s->frame);
	if (!pipe.convert(s->frame, s->frames, w, h)) {
		fail(s, "can't convert the captured picture");
		return false;
	}
	AVFrame *in = s->frame;
	if (s->enc->pix_fmt == AV_PIX_FMT_YUV420P) {
		bool ok = nv12_to_i420(s->frame, s->planar);
		av_frame_unref(s->frame);
		if (!ok) {
			fail(s, "can't convert the captured picture");
			return false;
		}
		in = s->planar;
	}
	in->pts = static_cast<int64_t>(pts);
	in->color_range = AVCOL_RANGE_MPEG;
	in->colorspace = AVCOL_SPC_BT709;
	if (s->want_key.exchange(false)) {
		in->pict_type = AV_PICTURE_TYPE_I;
		in->flags |= AV_FRAME_FLAG_KEY;
	} else {
		in->pict_type = AV_PICTURE_TYPE_NONE;
		in->flags &= ~AV_FRAME_FLAG_KEY;
	}
	int err = avcodec_send_frame(s->enc, in);
	av_frame_unref(in);
	if (err < 0) {
		fail(s, "the encoder refused a frame");
		return false;
	}
	// For an encoder that polls, until this frame's packet is out, but
	// never past the next frame's turn.
	bool poll = polls_output(s->encoder_name.c_str());
	uint64_t give_up = now_us() + 1'000'000 / static_cast<uint64_t>(s->config.fps);
	bool got = false;
	for (;;) {
		err = avcodec_receive_packet(s->enc, s->pkt);
		if (err == AVERROR(EAGAIN) && poll && !got && now_us() < give_up && !s->stop.load()) {
			continue;
		}
		if (err == AVERROR(EAGAIN) || err == AVERROR_EOF) {
			break;
		}
		if (err < 0) {
			fail(s, "the encoder failed");
			return false;
		}
		got = true;
		Encoded e;
		e.data.assign(s->pkt->data, s->pkt->data + s->pkt->size);
		e.pts_us = static_cast<uint64_t>(s->pkt->pts);
		e.codec = s->codec;
		e.key = (s->pkt->flags & AV_PKT_FLAG_KEY) != 0;
		av_packet_unref(s->pkt);
		sets.fix(e.data, e.key);
		queue(s, std::move(e));
		int starting = YV_SHARE_STARTING;
		s->state.compare_exchange_strong(starting, YV_SHARE_LIVE);
	}
	return true;
}

uint64_t now_us() {
	return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
									 std::chrono::steady_clock::now().time_since_epoch())
	                                 .count());
}

// What follows the last '_' of an encoder's name, which says whose GPU
// it's on ("nvenc", "amf", "qsv", ...); "" for one without.
std::string vendor_of(const std::string &encoder) {
	size_t at = encoder.rfind('_');
	return at == std::string::npos ? std::string() : encoder.substr(at + 1);
}

/*
pick_encoder is the encoder named in the config, else the best that
works of those the viewers can decode (`codecs`; 0 for any), or the best
that works at all if none of those does. With `current` (sharing
already), it keeps to that one's GPU, which the pipeline was made for,
or to software; "" if neither has anything they can decode.
*/
std::string pick_encoder(yv_share *s, uint32_t codecs, const std::string &current) {
	if (s->config.encoder[0]) {
		return s->config.encoder;
	}
	int n = yv_list_encoders(s->ctx, nullptr, 0);
	std::vector<yv_encoder> list(n);
	n = yv_list_encoders(s->ctx, list.data(), n);
	auto decodable = [&](const yv_encoder &e) {
		return codecs == 0 || (codecs & (1u << e.codec)) != 0;
	};
	if (!current.empty()) {
		std::string vendor = vendor_of(current);
		for (int i = 0; i < n; i++) {
			if (list[i].works && decodable(list[i]) && list[i].hardware &&
			    vendor_of(list[i].name) == vendor) {
				return list[i].name;
			}
		}
		for (int i = 0; i < n; i++) {
			if (list[i].works && decodable(list[i]) && !list[i].hardware) {
				return list[i].name;
			}
		}
		return {};
	}
	for (int i = 0; i < n; i++) {
		if (list[i].works && decodable(list[i])) {
			return list[i].name;
		}
	}
	for (int i = 0; i < n; i++) {
		if (list[i].works) {
			return list[i].name;
		}
	}
	return {};
}

/*
follow_codecs takes up yv_share_set_codecs's codecs: if they rule out
what's being encoded, another encoder takes over (encode opens it, with
a keyframe). One that's still fine is kept, even if a better one would
now do: changing costs a keyframe, and viewers come and go.
*/
void follow_codecs(yv_share *s, Parameter_Sets &sets) {
	uint32_t want = s->want_codecs.load();
	if (want == s->codecs || s->config.encoder[0]) {
		return;
	}
	s->codecs = want;
	if (want == 0 || (want & (1u << s->codec)) != 0) {
		return;
	}
	std::string next = pick_encoder(s, want, s->encoder_name);
	if (next.empty()) {
		log(YV_LOG_WARN, "share: nothing else here encodes what the viewers can decode");
		return;
	}
	log(YV_LOG_INFO, "share: %s -> %s, for the viewers", s->encoder_name.c_str(), next.c_str());
	s->encoder_name = next;
	s->codec = codec_of(next.c_str());
	sets = Parameter_Sets(s->codec);
	close_encoder(s);
}

void run(yv_share *s) {
	s->codecs = s->want_codecs.load();
	s->encoder_name = pick_encoder(s, s->codecs, {});
	if (s->encoder_name.empty()) {
		fail(s, "this computer has no video encoder that works");
		return;
	}
	s->codec = codec_of(s->encoder_name.c_str());
	s->kbit = s->config.kbit;
	std::unique_ptr<Pipeline> pipe = make_pipeline();
	std::string error;
	if (!pipe) {
		fail(s, "sharing isn't possible on this system");
		return;
	}
	if (!pipe->open(s->config, s->encoder_name.c_str(), s->stop, error)) {
		if (pipe->cancelled()) {
			log(YV_LOG_INFO, "share: cancelled in the system's picker");
			s->state.store(YV_SHARE_CANCELLED);
			return;
		}
		fail(s, error);
		return;
	}
	s->frame = av_frame_alloc();
	s->planar = av_frame_alloc();
	s->pkt = av_packet_alloc();
	Parameter_Sets sets(s->codec);

	const uint64_t interval = 1'000'000 / static_cast<uint64_t>(s->config.fps);
	uint64_t next_due = 0;
	bool pending = false; // captured, not yet encoded
	while (!s->stop.load()) {
		uint64_t now = now_us();
		int wait_ms = 100;
		if (pending) {
			wait_ms = next_due > now ? static_cast<int>((next_due - now + 999) / 1000) : 0;
		}
		bool closed = false;
		if (pipe->wait(wait_ms, closed)) {
			pending = true;
		}
		if (closed) {
			fail(s, "what was shared went away");
			break;
		}
		if (s->stop.load()) {
			break;
		}
		now = now_us();
		bool have = pipe->width() > 0;
		bool key = s->want_key.load() && have;
		if ((pending && now >= next_due) || key) {
			if (!encode(s, *pipe, sets, now)) {
				break;
			}
			pending = false;
			// On the beat, unless we've fallen a whole frame behind.
			next_due = (next_due + interval + interval < now) ? now + interval : next_due + interval;
		}
	}
	close_encoder(s);
	av_frame_free(&s->frame);
	av_frame_free(&s->planar);
	av_packet_free(&s->pkt);
	pipe.reset();
}

} // namespace

} // namespace yv

extern "C" {

YV_API uint64_t yv_clock_us(void) {
	return yv::now_us();
}

YV_API yv_share *yv_share_start(yv_context *ctx, const yv_share_config *config) {
	if (!ctx || !config) {
		return nullptr;
	}
	auto *s = new yv_share;
	s->ctx = ctx;
	s->config = *config;
	s->config.encoder[sizeof(s->config.encoder) - 1] = 0;
	s->want_codecs.store(s->config.codecs);
	if (s->config.fps <= 0 || s->config.fps > 240) {
		s->config.fps = 60;
	}
	if (s->config.kbit == 0) {
		s->config.kbit = 6000;
	}
	s->encoding_kbit.store(s->config.kbit);
	s->thread = std::thread(yv::run, s);
	return s;
}

YV_API bool yv_share_pull(yv_share *s, yv_packet *out) {
	if (!s || !out) {
		return false;
	}
	std::lock_guard<std::mutex> lock(s->mutex);
	if (s->queue.empty()) {
		return false;
	}
	s->pulled = std::move(s->queue.front());
	s->queue.pop_front();
	out->data = s->pulled.data.data();
	out->size = s->pulled.data.size();
	out->pts_us = s->pulled.pts_us;
	out->codec = s->pulled.codec;
	out->key = s->pulled.key;
	return true;
}

YV_API void yv_share_request_key(yv_share *s) {
	if (s) {
		s->want_key.store(true);
	}
}

YV_API void yv_share_set_bitrate(yv_share *s, uint32_t kbit) {
	if (s && kbit > 0) {
		s->want_kbit.store(kbit);
	}
}

YV_API uint32_t yv_share_get_bitrate(yv_share *s) {
	return s ? s->encoding_kbit.load() : 0;
}

YV_API void yv_share_set_codecs(yv_share *s, uint32_t codecs) {
	if (s) {
		s->want_codecs.store(codecs);
	}
}

YV_API yv_share_state yv_share_get_state(yv_share *s) {
	return s ? static_cast<yv_share_state>(s->state.load()) : YV_SHARE_FAILED;
}

YV_API const char *yv_share_error(yv_share *s) {
	if (!s || s->state.load() != YV_SHARE_FAILED) {
		return "";
	}
	return s->error.c_str();
}

YV_API void yv_share_stop(yv_share *s) {
	if (!s) {
		return;
	}
	s->stop.store(true);
	s->thread.join();
	delete s;
}

} // extern "C"
