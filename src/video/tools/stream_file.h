/*
Splitting a raw video file into the whole frames yv_view_push takes:
H.264 or HEVC in Annex B (.h264/.264, .hevc/.h265/.265) or AV1 as a
low overhead OBU stream (.obu, .av1), which is what FFmpeg writes with
`-f h264`, `-f hevc` and `-f obu`. Test material for yv-loopback --play.
*/
#pragma once

#include "yap_video.h"

#include <string>
#include <vector>

struct Stream_Frame {
	size_t offset, size;
	bool key;
};

struct Stream_File {
	yv_codec codec;
	std::vector<uint8_t> data;
	std::vector<Stream_Frame> frames;
};

// load_stream reads and splits `path`; false, with `error` set, if it can't.
bool load_stream(const char *path, Stream_File &out, std::string &error);
