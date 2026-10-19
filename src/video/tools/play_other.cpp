/*
yv-loopback without a window of its own (Linux, macOS): --play needs
one, so only --share works, and only as far as encoding. It prints the
frame rate, bitrate and how long capturing and encoding took once a
second, and --out saves the stream for --play on Windows, or ffprobe.
*/
#include "play.h"

#include <chrono>
#include <cstdio>
#include <string>
#include <thread>

int play(yv_context *ctx, const Play_Options &opt) {
	if (!opt.share) {
		fprintf(stderr, "--play needs a window, which only Windows has so far\n");
		return 1;
	}
	// macOS: the first time, its prompt; after that, its settings.
	if (!opt.camera && !yv_capture_allowed(ctx, true)) {
		fprintf(stderr, "capturing isn't allowed: allow it in the settings this opens (for the "
		                "terminal, on macOS), then run this again\n");
		yv_open_capture_settings(ctx);
		return 1;
	}
	yv_share *share = start_share(ctx, opt);
	if (!share) {
		return 1;
	}
	double seconds = opt.seconds > 0 ? opt.seconds : 10;
	printf("for %.0f seconds\n", seconds);

	using Clock = std::chrono::steady_clock;
	auto start = Clock::now(), last = start;
	FILE *out = nullptr;
	bool live = false, failed = false;
	uint64_t frames = 0, bytes = 0, keys = 0, encode_us = 0;
	uint64_t last_frames = 0, last_bytes = 0, last_encode = 0;
	bool switched = false;
	for (;;) {
		follow_then(share, opt, std::chrono::duration<double>(Clock::now() - start).count(),
		            switched);
		yv_share_state st = yv_share_get_state(share);
		if (st == YV_SHARE_FAILED) {
			fprintf(stderr, "share failed: %s\n", yv_share_error(share));
			failed = true;
			break;
		}
		if (st == YV_SHARE_LIVE && !live) {
			printf("share is live\n");
			live = true;
		}
		yv_packet p;
		while (yv_share_pull(share, &p)) {
			if (opt.out && !out) {
				std::string path = std::string(opt.out) + stream_extension(p.codec);
				out = fopen(path.c_str(), "wb");
				if (out) {
					printf("saving the stream to %s\n", path.c_str());
				}
			}
			if (out) {
				fwrite(p.data, 1, p.size, out);
			}
			frames++;
			bytes += p.size;
			keys += p.key ? 1 : 0;
			encode_us += yv_clock_us() - p.pts_us;
		}
		auto now = Clock::now();
		double since = std::chrono::duration<double>(now - last).count();
		if (since >= 1.0) {
			uint64_t n = frames - last_frames;
			printf("%llu frames (%.0f/s), %.1f Mbit/s, encoded after %.1f ms, %llu keyframes\n",
			       static_cast<unsigned long long>(frames), n / since,
			       (bytes - last_bytes) * 8 / since / 1e6,
			       n ? (encode_us - last_encode) / 1000.0 / n : 0.0,
			       static_cast<unsigned long long>(keys));
			last = now;
			last_frames = frames;
			last_bytes = bytes;
			last_encode = encode_us;
		}
		if (std::chrono::duration<double>(now - start).count() >= seconds) {
			break;
		}
		std::this_thread::sleep_for(std::chrono::milliseconds(2));
	}
	yv_share_stop(share);
	if (out) {
		fclose(out);
	}
	printf("encoded %llu frames\n", static_cast<unsigned long long>(frames));
	return failed || frames == 0 ? 1 : 0;
}
