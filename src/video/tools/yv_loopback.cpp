/*
yv-loopback: the library on its own, without yap. It lists what the
library sees (--list), decodes a file and shows it in a window as the
client would (--play), or shares the screen into that window (--share),
with bitrate and latency printed, to try encoders on new hardware.

	yv-loopback --list [--debug]
	yv-loopback --play <file> [--fps N] [--seconds S] [--once] [--dump picture.bmp] [--debug]
	yv-loopback --share [--monitor ID | --window ID] [--encoder NAME] [--kbit N] [--fps N]
	                    [--max WxH] [--seconds S] [--dump picture.bmp] [--out stream]
	                    [--then-kbit N] [--debug]

	yv-loopback --camera [ID] [--encoder NAME] [--kbit N] [--fps N] [--max WxH]
	                    [--seconds S] [--dump picture.bmp] [--out stream]
	                    [--then-kbit N] [--then-max WxH] [--debug]

--out saves what the share encoded, with the extension --play needs
added (.h264, .hevc or .obu). --then-kbit changes the bitrate 3 seconds
in, as the client does when its viewers fall behind. --camera shares a
camera (the first, or the one with that ID from --list) instead of the
screen, and --then-max has it fit a smaller size 3 seconds in, as the
client does when more cameras come on in the room.
*/
#include "play.h"
#include "yap_video.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#endif

namespace {

const char *level_names[] = {"debug", "info", "warn", "error"};

void print_log(void *, yv_log_level level, const char *msg) {
	fprintf(stderr, "[%s] %s\n", level_names[level], msg);
}

const char *codec_name(yv_codec c) {
	switch (c) {
	case YV_CODEC_H264:
		return "H.264";
	case YV_CODEC_HEVC:
		return "HEVC";
	case YV_CODEC_AV1:
		return "AV1";
	}
	return "?";
}

int list(yv_context *ctx) {
	printf("yap_video %s\n", yv_version_string());

	int n = yv_list_sources(ctx, nullptr, 0);
	std::vector<yv_source> sources(n);
	n = yv_list_sources(ctx, sources.data(), n);
	if (!yv_capture_allowed(ctx, false)) {
		printf("\ncapturing isn't allowed yet; --share asks\n");
	}
	if (yv_system_picker(ctx)) {
		printf("\nsources: chosen in the system's picker\n");
	}
	printf("\nmonitors:\n");
	for (const yv_source &s : sources) {
		if (s.kind == YV_SOURCE_MONITOR) {
			printf("  %#llx  %dx%d at %d,%d  %s (%s)%s\n", static_cast<unsigned long long>(s.id),
			       s.width, s.height, s.x, s.y, s.name, s.app, s.primary ? ", primary" : "");
		}
	}
	printf("\nwindows:\n");
	for (const yv_source &s : sources) {
		if (s.kind == YV_SOURCE_WINDOW) {
			printf("  %#llx  %dx%d  [%s] %s\n", static_cast<unsigned long long>(s.id), s.width,
			       s.height, s.app, s.name);
		}
	}

	n = yv_list_cameras(ctx, nullptr, 0);
	std::vector<yv_camera> cameras(n);
	n = yv_list_cameras(ctx, cameras.data(), n);
	printf("\ncameras:\n");
	if (!yv_camera_allowed(ctx, false)) {
		printf("  not allowed (the system's privacy settings)\n");
	}
	if (n == 0) {
		printf("  none\n");
	}
	for (int i = 0; i < n; i++) {
		const yv_camera &c = cameras[static_cast<size_t>(i)];
		printf("  %s, up to %dx%d at %d fps%s\n    %s\n", c.name, c.max_width, c.max_height,
		       c.max_fps, c.front ? ", front" : "", c.id);
	}

	n = yv_list_encoders(ctx, nullptr, 0);
	std::vector<yv_encoder> encoders(n);
	n = yv_list_encoders(ctx, encoders.data(), n);
	printf("\nencoders:\n");
	if (n == 0) {
		printf("  none in this build\n");
	}
	for (const yv_encoder &e : encoders) {
		printf("  %-6s %-14s %-28s %s\n", codec_name(e.codec), e.name, e.label,
		       e.works ? "works" : "doesn't work here");
	}
	return 0;
}

void usage() {
	fprintf(stderr,
	        "usage: yv-loopback --list [--debug]\n"
	        "       yv-loopback --play <file.h264|.hevc|.obu> [--fps N] [--seconds S]\n"
	        "                   [--once] [--dump picture.bmp] [--debug]\n"
	        "       yv-loopback --share [--monitor ID | --window ID] [--encoder NAME]\n"
	        "                   [--kbit N] [--fps N] [--max WxH] [--seconds S]\n"
	        "                   [--dump picture.bmp] [--out stream] [--then-kbit N] [--debug]\n"
	        "       yv-loopback --camera [ID] [--encoder NAME] [--kbit N] [--fps N] [--max WxH]\n"
	        "                   [--seconds S] [--dump picture.bmp] [--out stream]\n"
	        "                   [--then-kbit N] [--then-max WxH] [--debug]\n");
}

} // namespace

namespace {

yv_share_config share_config(yv_context *ctx, const Play_Options &opt) {
	yv_share_config cfg{};
	cfg.kind = opt.kind;
	cfg.source = opt.source;
	if (cfg.source == 0) {
		std::vector<yv_source> list(yv_list_sources(ctx, nullptr, 0));
		int n = yv_list_sources(ctx, list.data(), static_cast<int>(list.size()));
		bool found = false;
		for (int i = 0; i < n; i++) {
			if (list[i].kind == YV_SOURCE_MONITOR && (list[i].primary || !found)) {
				cfg.kind = YV_SOURCE_MONITOR;
				cfg.source = list[i].id;
				found = true;
			}
		}
	}
	snprintf(cfg.encoder, sizeof(cfg.encoder), "%s", opt.encoder);
	cfg.fps = opt.fps;
	cfg.kbit = opt.kbit;
	cfg.max_width = opt.max_w;
	cfg.max_height = opt.max_h;
	cfg.cursor = true;
	return cfg;
}

} // namespace

yv_share *start_share(yv_context *ctx, const Play_Options &opt) {
	if (!opt.camera) {
		yv_share_config cfg = share_config(ctx, opt);
		printf("sharing %#llx\n", static_cast<unsigned long long>(cfg.source));
		return yv_share_start(ctx, &cfg);
	}
	yv_camera_config cfg{};
	snprintf(cfg.camera, sizeof(cfg.camera), "%s", opt.camera_id);
	snprintf(cfg.encoder, sizeof(cfg.encoder), "%s", opt.encoder);
	cfg.fps = opt.fps;
	cfg.kbit = opt.kbit;
	cfg.max_width = opt.max_w;
	cfg.max_height = opt.max_h;
	printf("sharing the camera %s\n", opt.camera_id[0] ? opt.camera_id : "(the first)");
	return yv_camera_start(ctx, &cfg);
}

void follow_then(yv_share *share, const Play_Options &opt, double seconds, bool &done) {
	if (done || seconds < 3) {
		return;
	}
	done = true;
	if (opt.then_kbit) {
		printf("bitrate now %u kbit/s\n", opt.then_kbit);
		yv_share_set_bitrate(share, opt.then_kbit);
	}
	if (opt.then_w) {
		printf("now at most %dx%d\n", opt.then_w, opt.then_h);
		yv_share_configure(share, opt.fps, opt.then_w, opt.then_h, opt.then_kbit ? opt.then_kbit : opt.kbit);
	}
}

const char *stream_extension(yv_codec codec) {
	switch (codec) {
	case YV_CODEC_H264:
		return ".h264";
	case YV_CODEC_HEVC:
		return ".hevc";
	case YV_CODEC_AV1:
		return ".obu";
	}
	return "";
}

int main(int argc, char **argv) {
#ifdef _WIN32
	// Window sizes in real pixels, as the client sees them.
	SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
	SetConsoleOutputCP(CP_UTF8);
#endif
	bool do_list = false;
	Play_Options play_opt;
	yv_log_level level = YV_LOG_INFO;
	for (int i = 1; i < argc; i++) {
		bool more = i + 1 < argc;
		if (strcmp(argv[i], "--list") == 0) {
			do_list = true;
		} else if (strcmp(argv[i], "--play") == 0 && more) {
			play_opt.path = argv[++i];
		} else if (strcmp(argv[i], "--share") == 0) {
			play_opt.share = true;
		} else if (strcmp(argv[i], "--camera") == 0) {
			play_opt.share = play_opt.camera = true;
			if (more && strncmp(argv[i + 1], "--", 2) != 0) {
				play_opt.camera_id = argv[++i];
			}
		} else if (strcmp(argv[i], "--then-max") == 0 && more) {
			if (sscanf(argv[++i], "%dx%d", &play_opt.then_w, &play_opt.then_h) != 2) {
				usage();
				return 2;
			}
		} else if (strcmp(argv[i], "--monitor") == 0 && more) {
			play_opt.kind = YV_SOURCE_MONITOR;
			play_opt.source = strtoull(argv[++i], nullptr, 0);
		} else if (strcmp(argv[i], "--window") == 0 && more) {
			play_opt.kind = YV_SOURCE_WINDOW;
			play_opt.source = strtoull(argv[++i], nullptr, 0);
		} else if (strcmp(argv[i], "--encoder") == 0 && more) {
			play_opt.encoder = argv[++i];
		} else if (strcmp(argv[i], "--kbit") == 0 && more) {
			play_opt.kbit = static_cast<unsigned>(atoi(argv[++i]));
		} else if (strcmp(argv[i], "--max") == 0 && more) {
			if (sscanf(argv[++i], "%dx%d", &play_opt.max_w, &play_opt.max_h) != 2) {
				usage();
				return 2;
			}
		} else if (strcmp(argv[i], "--fps") == 0 && more) {
			play_opt.fps = atoi(argv[++i]);
		} else if (strcmp(argv[i], "--seconds") == 0 && more) {
			play_opt.seconds = atof(argv[++i]);
		} else if (strcmp(argv[i], "--once") == 0) {
			play_opt.once = true;
		} else if (strcmp(argv[i], "--dump") == 0 && more) {
			play_opt.dump = argv[++i];
		} else if (strcmp(argv[i], "--out") == 0 && more) {
			play_opt.out = argv[++i];
		} else if (strcmp(argv[i], "--then-kbit") == 0 && more) {
			play_opt.then_kbit = static_cast<unsigned>(atoi(argv[++i]));
		} else if (strcmp(argv[i], "--debug") == 0) {
			level = YV_LOG_DEBUG;
		} else {
			usage();
			return 2;
		}
	}
	if (play_opt.fps <= 0) {
		play_opt.fps = 60;
	}
	if (int(do_list) + int(play_opt.path != nullptr) + int(play_opt.share) != 1) {
		usage();
		return 2;
	}
	if (yv_api_version() != YV_API_VERSION) {
		fprintf(stderr, "library is API version %u, this tool %u\n", yv_api_version(),
		        YV_API_VERSION);
		return 1;
	}
	yv_init init{};
	init.api_version = YV_API_VERSION;
	init.log = print_log;
	init.log_level = level;
	yv_context *ctx = yv_create(&init);
	if (!ctx) {
		return 1;
	}
	int rc = do_list ? list(ctx) : play(ctx, play_opt);
	yv_destroy(ctx);
	return rc;
}
