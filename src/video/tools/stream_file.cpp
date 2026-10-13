#include "stream_file.h"

#include <cctype>
#include <cstdio>
#include <cstring>

namespace {

bool ends_with(const std::string &s, const char *suffix) {
	size_t n = strlen(suffix);
	if (s.size() < n) {
		return false;
	}
	for (size_t i = 0; i < n; i++) {
		if (tolower(static_cast<unsigned char>(s[s.size() - n + i])) != suffix[i]) {
			return false;
		}
	}
	return true;
}

struct Nal {
	size_t start; // of its start code
	size_t body;  // of its header
};

// The NAL units of an Annex B stream, each from its start code.
std::vector<Nal> find_nals(const std::vector<uint8_t> &d) {
	std::vector<Nal> nals;
	for (size_t i = 0; i + 3 <= d.size(); i++) {
		if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1) {
			size_t start = (i > 0 && d[i - 1] == 0) ? i - 1 : i;
			nals.push_back({start, i + 3});
			i += 2;
		}
	}
	return nals;
}

/*
An access unit starts with whatever comes before its first slice: an
access unit delimiter, parameter sets, SEI, or the first slice itself
(first_mb_in_slice 0, or first_slice_segment_in_pic_flag, which is the
first bit after the header either way).
*/
void split_annex_b(Stream_File &f) {
	std::vector<Nal> nals = find_nals(f.data);
	bool hevc = f.codec == YV_CODEC_HEVC;
	size_t au_start = 0;
	bool have_slice = false, key = false;
	auto close = [&](size_t end) {
		if (have_slice && end > au_start) {
			f.frames.push_back({au_start, end - au_start, key});
		}
		au_start = end;
		have_slice = false;
		key = false;
	};
	for (const Nal &n : nals) {
		size_t after = n.body + (hevc ? 2 : 1);
		if (after >= f.data.size()) {
			continue;
		}
		uint8_t h = f.data[n.body];
		int type = hevc ? (h >> 1) & 0x3f : h & 0x1f;
		bool vcl = hevc ? type < 32 : (type >= 1 && type <= 5);
		bool first_slice = vcl && (f.data[after] & 0x80);
		bool starts_au = hevc ? (type >= 32 && type <= 35) || type == 39 // VPS, SPS, PPS, AUD, SEI
		                      : type == 9 || type == 7 || type == 8 || type == 6;
		if ((starts_au || first_slice) && have_slice) {
			close(n.start);
		}
		if (vcl) {
			have_slice = true;
			key = key || (hevc ? type >= 16 && type <= 21 : type == 5);
		}
	}
	close(f.data.size());
}

bool read_leb128(const std::vector<uint8_t> &d, size_t &pos, uint64_t &value) {
	value = 0;
	for (int i = 0; i < 8; i++) {
		if (pos >= d.size()) {
			return false;
		}
		uint8_t b = d[pos++];
		value |= static_cast<uint64_t>(b & 0x7f) << (7 * i);
		if (!(b & 0x80)) {
			return true;
		}
	}
	return false;
}

// A temporal unit starts with a temporal delimiter; one that has a
// sequence header is taken for a keyframe.
bool split_obu(Stream_File &f, std::string &error) {
	const std::vector<uint8_t> &d = f.data;
	size_t pos = 0, tu_start = 0;
	bool key = false, any = false;
	while (pos < d.size()) {
		size_t obu_start = pos;
		uint8_t h = d[pos++];
		int type = (h >> 3) & 0xf;
		if (h & 0x04) {
			pos++; // the extension header
		}
		if (!(h & 0x02)) {
			error = "OBUs without sizes (use FFmpeg's -f obu)";
			return false;
		}
		uint64_t size;
		if (!read_leb128(d, pos, size) || pos + size > d.size()) {
			error = "a truncated OBU";
			return false;
		}
		pos += size;
		if (type == 2 && any) { // temporal delimiter
			f.frames.push_back({tu_start, obu_start - tu_start, key});
			tu_start = obu_start;
			key = false;
		}
		any = true;
		key = key || type == 1; // sequence header
	}
	if (any) {
		f.frames.push_back({tu_start, d.size() - tu_start, key});
	}
	return true;
}

} // namespace

bool load_stream(const char *path, Stream_File &out, std::string &error) {
	std::string p = path;
	if (ends_with(p, ".h264") || ends_with(p, ".264")) {
		out.codec = YV_CODEC_H264;
	} else if (ends_with(p, ".hevc") || ends_with(p, ".h265") || ends_with(p, ".265")) {
		out.codec = YV_CODEC_HEVC;
	} else if (ends_with(p, ".obu") || ends_with(p, ".av1")) {
		out.codec = YV_CODEC_AV1;
	} else {
		error = "unknown file type (.h264, .hevc or .obu)";
		return false;
	}
	FILE *file = fopen(path, "rb");
	if (!file) {
		error = "can't open it";
		return false;
	}
	uint8_t buf[65536];
	size_t n;
	while ((n = fread(buf, 1, sizeof(buf), file)) > 0) {
		out.data.insert(out.data.end(), buf, buf + n);
	}
	fclose(file);
	if (out.codec == YV_CODEC_AV1) {
		if (!split_obu(out, error)) {
			return false;
		}
	} else {
		split_annex_b(out);
	}
	if (out.frames.empty()) {
		error = "no frames in it";
		return false;
	}
	return true;
}
