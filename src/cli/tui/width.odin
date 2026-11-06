package tui

import "core:unicode/utf8"

// How many terminal cells a rune takes: 0 for what combines with the rune before
// it or has no width of its own (combining marks, joiners, variation selectors),
// 2 for wide characters (CJK, most emoji), else 1. This is the usual
// wcwidth approximation, with the emoji blocks that terminals draw wide. It is
// not the whole of Unicode's table: a sequence such as a family emoji is
// drawn as the emoji it is made of, because joiners are zero-width here.
rune_width :: proc(r: rune) -> int {
	switch {
	case r == 0:
		return 0
	case r < 32 || (r >= 0x7f && r < 0xa0):
		return 0
	case r < 0x300:
		return 1
	}
	if in_ranges(r, ZERO_WIDTH[:]) {
		return 0
	}
	if in_ranges(r, WIDE[:]) {
		return 2
	}
	return 1
}

// string_width is the cells a string takes.
string_width :: proc(s: string) -> (w: int) {
	for r in s {
		w += rune_width(r)
	}
	return
}

// cut_to_width returns the longest start of `s` that is at most `width` cells wide.
cut_to_width :: proc(s: string, width: int) -> string {
	w := 0
	for r, i in s {
		rw := rune_width(r)
		if w + rw > width {
			return s[:i]
		}
		w += rw
	}
	return s
}

// first_rune_size is the length in bytes of the rune that starts `s`.
first_rune_size :: proc(s: string) -> int {
	_, n := utf8.decode_rune_in_string(s)
	return n
}

@(private)
Range :: struct {
	lo, hi: rune,
}

@(private = "file")
in_ranges :: proc(r: rune, ranges: []Range) -> bool {
	lo, hi := 0, len(ranges)
	for lo < hi {
		mid := (lo + hi) / 2
		switch {
		case r < ranges[mid].lo:
			hi = mid
		case r > ranges[mid].hi:
			lo = mid + 1
		case:
			return true
		}
	}
	return false
}

// Sorted, for the binary search.
@(private)
ZERO_WIDTH := [?]Range {
	{0x0300, 0x036f}, // combining diacritics
	{0x0483, 0x0489},
	{0x0591, 0x05bd},
	{0x0610, 0x061a},
	{0x064b, 0x065f},
	{0x200b, 0x200f}, // zero width space, joiners, direction marks
	{0x202a, 0x202e},
	{0x2060, 0x2064},
	{0x20d0, 0x20ff}, // combining marks for symbols
	{0xfe00, 0xfe0f}, // variation selectors
	{0xfe20, 0xfe2f},
	{0xfeff, 0xfeff},
	{0x1f3fb, 0x1f3ff}, // skin tones, which follow the emoji they change
	{0xe0100, 0xe01ef},
}

@(private)
WIDE := [?]Range {
	{0x1100, 0x115f}, // Hangul Jamo
	{0x231a, 0x231b},
	{0x23e9, 0x23ec},
	{0x23f0, 0x23f0},
	{0x23f3, 0x23f3},
	{0x25fd, 0x25fe},
	{0x2614, 0x2615},
	{0x2648, 0x2653},
	{0x267f, 0x267f},
	{0x2693, 0x2693},
	{0x26a1, 0x26a1},
	{0x26aa, 0x26ab},
	{0x26bd, 0x26be},
	{0x26c4, 0x26c5},
	{0x26ce, 0x26ce},
	{0x26d4, 0x26d4},
	{0x26ea, 0x26ea},
	{0x26f2, 0x26f3},
	{0x26f5, 0x26f5},
	{0x26fa, 0x26fa},
	{0x26fd, 0x26fd},
	{0x2705, 0x2705},
	{0x270a, 0x270b},
	{0x2728, 0x2728},
	{0x274c, 0x274c},
	{0x274e, 0x274e},
	{0x2753, 0x2755},
	{0x2757, 0x2757},
	{0x2795, 0x2797},
	{0x27b0, 0x27b0},
	{0x27bf, 0x27bf},
	{0x2b1b, 0x2b1c},
	{0x2b50, 0x2b50},
	{0x2b55, 0x2b55},
	{0x2e80, 0x303e}, // CJK radicals, symbols and punctuation
	{0x3041, 0x33ff}, // kana, CJK compatibility
	{0x3400, 0x4dbf},
	{0x4e00, 0xa4cf},
	{0xa960, 0xa97f},
	{0xac00, 0xd7a3}, // Hangul syllables
	{0xf900, 0xfaff},
	{0xfe30, 0xfe6f},
	{0xff01, 0xff60}, // fullwidth forms
	{0xffe0, 0xffe6},
	{0x1f004, 0x1f004},
	{0x1f0cf, 0x1f0cf},
	{0x1f18e, 0x1f18e},
	{0x1f191, 0x1f19a},
	{0x1f200, 0x1f320},
	{0x1f32d, 0x1f335},
	{0x1f337, 0x1f37c},
	{0x1f37e, 0x1f393},
	{0x1f3a0, 0x1f3ca},
	{0x1f3cf, 0x1f3d3},
	{0x1f3e0, 0x1f3f0},
	{0x1f3f4, 0x1f3f4},
	{0x1f3f8, 0x1f43e},
	{0x1f440, 0x1f440},
	{0x1f442, 0x1f4fc},
	{0x1f4ff, 0x1f53d},
	{0x1f54b, 0x1f54e},
	{0x1f550, 0x1f567},
	{0x1f57a, 0x1f57a},
	{0x1f595, 0x1f596},
	{0x1f5a4, 0x1f5a4},
	{0x1f5fb, 0x1f64f},
	{0x1f680, 0x1f6c5},
	{0x1f6cc, 0x1f6cc},
	{0x1f6d0, 0x1f6d2},
	{0x1f6d5, 0x1f6d7},
	{0x1f6dc, 0x1f6df},
	{0x1f6eb, 0x1f6ec},
	{0x1f6f4, 0x1f6fc},
	{0x1f7e0, 0x1f7eb},
	{0x1f7f0, 0x1f7f0},
	{0x1f90c, 0x1f93a},
	{0x1f93c, 0x1f945},
	{0x1f947, 0x1f9ff},
	{0x1fa70, 0x1faff},
	{0x20000, 0x2fffd},
	{0x30000, 0x3fffd},
}

// decode reads the rune at byte i of s, and its size.
decode :: proc(s: string, i: int) -> (rune, int) {
	return utf8.decode_rune_in_string(s[i:])
}
