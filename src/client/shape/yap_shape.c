// Text shaping for the client (shape.odin, used by render/shape_native.odin),
// over kb_text_shape (deps/thirdparty/kb_text_shape, zlib license).
//
// kb_text_shape's own interface hands out its structs, whose layout changes
// between versions, so this file keeps them on the C side and gives Odin
// plain arrays instead: the fonts are registered once and referred to by
// number, and a line of text goes in as codepoints, each with the font that
// was chosen for it, and comes out as runs of glyphs. The runs are split
// where the direction, the script or the font changes and come in logical
// order; within a right-to-left run the glyphs are already in visual order
// (left to right). Putting the runs of a line in visual order is left to
// the caller, which knows where the line ends.
//
// The direction and script of each codepoint come from kb_text_shape's
// segmentation, fed one codepoint at a time (kbts_BreakEntireStringUtf32
// returned stray entries between the real ones in v2.21).
//
// Everything is used from one thread (the UI's).

#define KB_TEXT_SHAPE_IMPLEMENTATION
#define KB_TEXT_SHAPE_STATIC
#include "../../../deps/thirdparty/kb_text_shape/kb_text_shape.h"

#include <stdlib.h>
#include <string.h>

#include "yap_shape.h"

// How many fonts can be registered, and how many scripts each can be
// shaped for at once (a shape config each).
#define YS_MAX_FONTS 128
#define YS_MAX_CONFIGS 8

typedef struct ys_config {
	kbts_script script;
	kbts_shape_config *config;
	kbts_shape_scratchpad *scratchpad;
	kbts_glyph_config *glyph_config;
} ys_config;

typedef struct ys_font {
	int used;
	kbts_font font;
	ys_config configs[YS_MAX_CONFIGS];
	int config_count;
	int next_config; // which config to replace when all are taken
} ys_font;

static ys_font fonts[YS_MAX_FONTS];
static kbts_glyph_storage storage;

// The direction and script of each codepoint of the last line, kept between
// calls so they needn't be allocated every time.
static unsigned char *direction_of;
static unsigned char *grapheme_of; // 1 where a codepoint starts a grapheme
static kbts_script *script_of;
static int capacity;

int ys_font_add(const void *data, int size, int index)
{
	for (int i = 0; i < YS_MAX_FONTS; i++) {
		if (fonts[i].used) {
			continue;
		}
		kbts_font font = kbts_FontFromMemory((void *)data, size, index, 0, 0);
		if (!kbts_FontIsValid(&font)) {
			kbts_FreeFont(&font);
			return -1;
		}
		memset(&fonts[i], 0, sizeof(fonts[i]));
		fonts[i].used = 1;
		fonts[i].font = font;
		return i;
	}
	return -1;
}

static void config_free(ys_config *c)
{
	if (c->glyph_config) {
		kbts_DestroyGlyphConfig(c->glyph_config);
	}
	if (c->scratchpad) {
		kbts_DestroyShapeScratchpad(c->scratchpad);
	}
	if (c->config) {
		kbts_DestroyShapeConfig(c->config);
	}
	memset(c, 0, sizeof(*c));
}

void ys_font_remove(int font)
{
	if (font < 0 || font >= YS_MAX_FONTS || !fonts[font].used) {
		return;
	}
	ys_font *f = &fonts[font];
	for (int i = 0; i < f->config_count; i++) {
		config_free(&f->configs[i]);
	}
	kbts_FreeFont(&f->font);
	memset(f, 0, sizeof(*f));
}

void ys_shutdown(void)
{
	for (int i = 0; i < YS_MAX_FONTS; i++) {
		ys_font_remove(i);
	}
	kbts_FreeAllGlyphs(&storage);
	memset(&storage, 0, sizeof(storage));
	free(direction_of);
	free(grapheme_of);
	free(script_of);
	direction_of = 0;
	grapheme_of = 0;
	script_of = 0;
	capacity = 0;
}

// config_for returns the shaping state for a font and script, made the first
// time and kept (a few per font, the oldest replaced).
static ys_config *config_for(ys_font *f, kbts_script script)
{
	for (int i = 0; i < f->config_count; i++) {
		if (f->configs[i].script == script) {
			return &f->configs[i];
		}
	}
	ys_config *c;
	if (f->config_count < YS_MAX_CONFIGS) {
		c = &f->configs[f->config_count++];
	} else {
		c = &f->configs[f->next_config];
		f->next_config = (f->next_config + 1) % YS_MAX_CONFIGS;
		config_free(c);
	}
	c->script = script;
	c->config = kbts_CreateShapeConfig(&f->font, script, KBTS_LANGUAGE_DONT_KNOW, 0, 0);
	if (c->config) {
		c->scratchpad = kbts_CreateShapeScratchpad(c->config, 0, 0);
		c->glyph_config = kbts_CreateGlyphConfig(c->config, 0, 0, 0, 0);
	}
	if (!c->config || !c->scratchpad || !c->glyph_config) {
		config_free(c);
		return 0;
	}
	return c;
}

// segment fills direction_of, script_of and grapheme_of for `count` codepoints, and
// returns the line's (paragraph's) direction. A codepoint without a break of
// its own has the direction and script of the one before.
static kbts_direction segment(const int *codepoints, int count)
{
	memset(direction_of, 0, (size_t)count);
	memset(grapheme_of, 0, (size_t)count);
	grapheme_of[0] = 1;
	for (int i = 0; i < count; i++) {
		script_of[i] = KBTS_SCRIPT_DONT_KNOW;
	}
	kbts_direction paragraph = KBTS_DIRECTION_LTR;
	kbts_break_state state;
	memset(&state, 0, sizeof(state));
	kbts_BreakBegin(&state, KBTS_DIRECTION_DONT_KNOW, KBTS_JAPANESE_LINE_BREAK_STYLE_NORMAL, 0);
	for (int i = 0; i < count; i++) {
		kbts_BreakAddCodepoint(&state, codepoints[i], 1, i == count - 1);
		kbts_break b;
		while (kbts_Break(&state, &b)) {
			if (b.Position < 0 || b.Position >= count) {
				continue;
			}
			if (b.Flags & KBTS_BREAK_FLAG_DIRECTION) {
				direction_of[b.Position] = (unsigned char)b.Direction;
				if (b.Flags & KBTS_BREAK_FLAG_PARAGRAPH_DIRECTION) {
					paragraph = b.Direction;
				}
			}
			if (b.Flags & KBTS_BREAK_FLAG_GRAPHEME) {
				grapheme_of[b.Position] = 1;
			}
			if (b.Flags & KBTS_BREAK_FLAG_SCRIPT) {
				script_of[b.Position] = b.Script;
			}
		}
	}
	unsigned char direction = KBTS_DIRECTION_LTR;
	kbts_script script = KBTS_SCRIPT_DONT_KNOW;
	for (int i = 0; i < count; i++) {
		if (direction_of[i] != KBTS_DIRECTION_DONT_KNOW) {
			direction = direction_of[i];
		}
		direction_of[i] = direction;
		if (script_of[i] != KBTS_SCRIPT_DONT_KNOW) {
			script = script_of[i];
		}
		script_of[i] = script;
	}
	return paragraph;
}

int ys_shape(const int *codepoints, const unsigned short *font_of, int count, ys_glyph *glyphs,
             int glyph_capacity, int *glyph_count, ys_run *runs, int run_capacity, int *run_count,
             int *paragraph_rtl, unsigned char *grapheme_start)
{
	*glyph_count = 0;
	*run_count = 0;
	*paragraph_rtl = 0;
	if (count <= 0) {
		return YS_OK;
	}
	if (count > capacity) {
		int n = count * 2;
		unsigned char *d = realloc(direction_of, (size_t)n);
		if (d) {
			direction_of = d;
		}
		kbts_script *s = realloc(script_of, (size_t)n * sizeof(*script_of));
		if (s) {
			script_of = s;
		}
		unsigned char *g = realloc(grapheme_of, (size_t)n);
		if (g) {
			grapheme_of = g;
		}
		if (!d || !s || !g) {
			return YS_ERROR;
		}
		capacity = n;
	}
	*paragraph_rtl = segment(codepoints, count) == KBTS_DIRECTION_RTL;
	memcpy(grapheme_start, grapheme_of, (size_t)count);

	int glyphs_out = 0, runs_out = 0;
	int too_small = 0;
	for (int start = 0; start < count;) {
		// The run ends where the direction, the script or the font changes.
		int end = start + 1;
		while (end < count && font_of[end] == font_of[start] && direction_of[end] == direction_of[start] &&
		       script_of[end] == script_of[start]) {
			end++;
		}
		int font = font_of[start];
		int rtl = direction_of[start] == KBTS_DIRECTION_RTL;
		ys_config *c = 0;
		if (font < YS_MAX_FONTS && fonts[font].used) {
			c = config_for(&fonts[font], script_of[start]);
		}
		int first_glyph = glyphs_out;
		if (c) {
			kbts_ClearActiveGlyphs(&storage);
			for (int i = start; i < end; i++) {
				kbts_PushGlyph(&storage, &fonts[font].font, codepoints[i], c->glyph_config, i);
			}
			kbts_glyph_iterator it;
			kbts_shape_error err = kbts_ShapeDirect(c->scratchpad, &storage,
			                                        rtl ? KBTS_DIRECTION_RTL : KBTS_DIRECTION_LTR, &it);
			if (err != KBTS_SHAPE_ERROR_NONE) {
				return YS_ERROR;
			}
			kbts_glyph *g;
			while (kbts_GlyphIteratorNext(&it, &g)) {
				if (glyphs_out < glyph_capacity) {
					ys_glyph *o = &glyphs[glyphs_out];
					o->id = g->Id;
					o->font = (unsigned short)font;
					o->cluster = g->UserIdOrCodepointIndex;
					o->advance = g->AdvanceX;
					o->x_offset = g->OffsetX;
					o->y_offset = g->OffsetY;
				} else {
					too_small = 1;
				}
				glyphs_out++;
			}
		} else {
			// No font to shape with: a glyph 0 per codepoint, in visual
			// order, which the caller draws its own way.
			for (int i = start; i < end; i++) {
				int at = rtl ? end - 1 - (i - start) : i;
				if (glyphs_out < glyph_capacity) {
					ys_glyph *o = &glyphs[glyphs_out];
					memset(o, 0, sizeof(*o));
					o->font = (unsigned short)font;
					o->cluster = at;
				} else {
					too_small = 1;
				}
				glyphs_out++;
			}
		}
		if (runs_out < run_capacity) {
			ys_run *r = &runs[runs_out];
			r->first_glyph = first_glyph;
			r->glyph_count = glyphs_out - first_glyph;
			r->first = start;
			r->count = end - start;
			r->rtl = rtl;
		} else {
			too_small = 1;
		}
		runs_out++;
		start = end;
	}
	*glyph_count = glyphs_out;
	*run_count = runs_out;
	return too_small ? YS_TOO_SMALL : YS_OK;
}
