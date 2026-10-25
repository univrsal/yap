// keytest: does an encoder answer keyframe requests? See README.md.
//
// Shares a monitor (or what the system's picker gives) with the encoder
// named on the command line, asks for a keyframe once a second once the
// share is live, and prints which pulled packets are flagged as keyframes.
// Without an encoder, it lists the ones that work.
#include <yap_video.h>

#include <chrono>
#include <cstdio>
#include <thread>

using Clock = std::chrono::steady_clock;

static long long ms_since(Clock::time_point t) {
	return std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - t).count();
}

static void log_fn(void *, yv_log_level, const char *msg) {
	printf("  [yap_video] %s\n", msg);
}

int main(int argc, char **argv) {
	if (yv_api_version() != YV_API_VERSION) {
		fprintf(stderr, "the library is API %u, this was built against %d\n", yv_api_version(),
		        YV_API_VERSION);
		return 1;
	}
	yv_init init{};
	init.api_version = YV_API_VERSION;
	init.log = log_fn;
	init.log_level = YV_LOG_INFO;
	yv_context *ctx = yv_create(&init);
	if (!ctx) {
		return 1;
	}
	if (argc < 2) {
		yv_encoder enc[64];
		int n = yv_list_encoders(ctx, enc, 64);
		printf("usage: keytest <encoder>; these work here:\n");
		for (int i = 0; i < n && i < 64; i++) {
			if (enc[i].works) {
				printf("  %s\n", enc[i].name);
			}
		}
		yv_destroy(ctx);
		return 1;
	}

	yv_share_config cfg{};
	cfg.kind = YV_SOURCE_MONITOR;
	if (!yv_system_picker(ctx)) {
		yv_source src[16];
		if (yv_list_sources(ctx, src, 16) <= 0) {
			fprintf(stderr, "nothing to share\n");
			return 1;
		}
		cfg.source = src[0].id;
	} // else source 0 opens the system's picker
	snprintf(cfg.encoder, sizeof(cfg.encoder), "%s", argv[1]);
	cfg.fps = 60;
	cfg.max_width = 1920;
	cfg.max_height = 1080;
	cfg.kbit = 8000;
	yv_share *share = yv_share_start(ctx, &cfg);
	if (!share) {
		return 1;
	}

	// Until it's live (the picker may be waiting for an answer).
	while (yv_share_get_state(share) == YV_SHARE_STARTING) {
		std::this_thread::sleep_for(std::chrono::milliseconds(10));
	}
	if (yv_share_get_state(share) != YV_SHARE_LIVE) {
		fprintf(stderr, "share didn't start: %s\n", yv_share_error(share));
		yv_share_stop(share);
		yv_destroy(ctx);
		return 1;
	}

	Clock::time_point start = Clock::now();
	int asked = 0, answered = 0, frames = 0;
	long long asked_at = -1;
	while (ms_since(start) < 5500) {
		long long ms = ms_since(start);
		if (ms / 1000 > asked) {
			asked++;
			asked_at = ms;
			printf("%5lld ms: asking for a keyframe\n", ms);
			yv_share_request_key(share);
		}
		yv_packet p;
		while (yv_share_pull(share, &p)) {
			frames++;
			if (p.key) {
				printf("%5lld ms: frame %d is a keyframe, %zu bytes", ms, frames, p.size);
				if (asked_at >= 0) {
					printf(" (%lld ms after asking)", ms - asked_at);
					answered++;
					asked_at = -1;
				}
				printf("\n");
			}
		}
		if (yv_share_get_state(share) == YV_SHARE_FAILED) {
			printf("failed: %s\n", yv_share_error(share));
			break;
		}
		std::this_thread::sleep_for(std::chrono::milliseconds(2));
	}
	printf("%d frames, %d of %d keyframe requests answered: %s\n", frames, answered, asked,
	       answered == asked ? "OK" : "BROKEN");
	yv_share_stop(share);
	yv_destroy(ctx);
	return answered == asked ? 0 : 2;
}
