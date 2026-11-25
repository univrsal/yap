// The interface of yap_shape.c, which shape.odin binds.
#ifndef YAP_SHAPE_H
#define YAP_SHAPE_H

enum {
	YS_OK = 0,
	YS_TOO_SMALL = 1, // the arrays were too small; the counts say how big they need to be
	YS_ERROR = -1,
};

// A glyph of shaped text. Advances and offsets are in the font's units.
typedef struct ys_glyph {
	unsigned short id; // the glyph in its font (0: none)
	unsigned short font; // the font it is from, as ys_font_add numbered it
	int cluster; // the index of the (first) codepoint it was made from
	int advance;
	int x_offset;
	int y_offset;
} ys_glyph;

// A run of glyphs of one direction, script and font.
typedef struct ys_run {
	int first_glyph, glyph_count;
	int first, count; // its codepoints
	int rtl; // right to left; its glyphs are in visual order nonetheless
} ys_run;

// ys_font_add reads font `index` of a font file (which must stay in memory
// until the font is removed) and returns its number, or -1.
int ys_font_add(const void *data, int size, int index);
void ys_font_remove(int font);
// ys_shutdown removes all fonts and frees everything.
void ys_shutdown(void);

// ys_shape shapes a line of `count` codepoints, each with the number of its
// font (a number that isn't a font's makes glyphs 0 for those codepoints,
// one each, for the caller to draw itself). paragraph_rtl is set to whether
// the line's first strong direction is right to left. grapheme_start gets
// `count` bytes, 1 for each codepoint that starts a grapheme (a cluster the
// caret steps over whole).
int ys_shape(const int *codepoints, const unsigned short *font_of, int count, ys_glyph *glyphs,
             int glyph_capacity, int *glyph_count, ys_run *runs, int run_capacity, int *run_count,
             int *paragraph_rtl, unsigned char *grapheme_start);

#endif
