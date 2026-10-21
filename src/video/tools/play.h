// yv-loopback --play and --share: decode a file, or what a share of the
// screen encodes, through a view and show it. Where there's no window
// of our own yet (Linux, macOS), --share only encodes, and says how
// that goes.
#pragma once

#include "yap_video.h"

struct Play_Options {
	const char *path = nullptr;
	int fps = 60;
	double seconds = 0;          // stop after this long; 0 runs until closed
	bool once = false;           // push the file once instead of round and round
	const char *dump = nullptr;  // save the last picture as a BMP here

	// --share instead of a file.
	bool share = false;
	yv_source_kind kind = YV_SOURCE_MONITOR;
	uint64_t source = 0;          // 0: the primary monitor
	const char *encoder = "";     // "": the best
	unsigned kbit = 8000;
	unsigned then_kbit = 0; // switch to this bitrate 3 seconds in (yv_share_set_bitrate)
	int max_w = 1920, max_h = 1080;
	const char *out = nullptr; // the encoded stream, as --play reads it

	// --camera: a camera's share instead of the screen's (share is set too).
	bool camera = false;
	const char *camera_id = ""; // "": the first
	// Fit within this 3 seconds in (yv_share_configure), as a room's tier does.
	int then_w = 0, then_h = 0;
	bool then_pause = false; // pause 3 seconds in, go on 2 seconds later (yv_share_pause)
};

int play(yv_context *ctx, const Play_Options &opt);

// Starts what --share or --camera asks for: source 0 is the primary monitor.
yv_share *start_share(yv_context *ctx, const Play_Options &opt);

// Does what --then-kbit and --then-max ask for, once `seconds` since starting
// have gone by.
void follow_then(yv_share *share, const Play_Options &opt, double seconds, bool &done);

// The extension --play needs to read what --out wrote.
const char *stream_extension(yv_codec codec);
