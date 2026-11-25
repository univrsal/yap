# Fonts: using the system's fonts, shaping and memory

Written 2026-11-25 on `better-fonts` (74d3b44). This is an exploration, not
something built yet: what it would take for the client to optionally use
the fonts the operating system ships, how to draw scripts that need shaping
(Arabic, Hebrew, Indic) and mixed text, and how to keep memory low while
doing so. Memory figures marked *estimate* have not been measured.

## Today

- `render/font.odin`: Roboto (Regular, Bold, Italic, Bold Italic) and
  JetBrains Mono, embedded with `#load` and rasterized with stb_truetype.
  At load, every BMP codepoint is looked up in the face (`face_init`) and
  every glyph the face has is packed into one atlas up front
  (`font_build_atlas`). That is fine for Roboto (a few thousand glyphs), but
  could not work for a CJK font of 20 000+ glyphs.
- `render/unifont.odin`: GNU Unifont as the fallback for the rest of the
  BMP, decoded from an 877 KB chart on first need. Its atlas is filled
  lazily, one slot per glyph the first time text uses it, and emptied when
  full. That lazy atlas is the pattern the rest of this document builds on.
- `render/emoji_atlas.odin`: 1012 emoji in one 2048x2048 RGBA sheet
  (`assets/emoji.webp`, made by `tools/emoji.py` from Apple Color Emoji):
  16.8 MB of video memory plus mipmaps, and a 16.8 MB buffer while it is
  decoded, whether one emoji is ever shown or not.
- Nothing is shaped or reordered: Arabic is shown as isolated letters from
  left to right, combining marks are not positioned, and emoji sequences
  (flags, skin tones, ZWJ sequences) fall apart into their parts.
- `proto/sanitize.odin` drops invisible formatting characters from all text
  (`invisible`), which includes the joiners and variation selectors. See
  "The protocol" below: this blocks shaping more than anything in the
  client does.

## 1. Finding the system's fonts

The question for each platform is "which installed font has this
character, for this language", and the answer we need is a file path (and
an index into a collection) that we can hand to stb_truetype and
kb_text_shape.

| OS | API | Notes |
| --- | --- | --- |
| Windows | DirectWrite: `IDWriteFontFallback::MapCharacters` (8.1+) on the system fallback, then `IDWriteLocalFontFileLoader::GetFilePathFromKey` for the path | Needs COM bindings of our own (~150 lines of vtables). A cheaper first step is a fixed table, since the set has been stable since Windows 10 (below). |
| macOS | CoreText: `CTFontCreateForString`, or `CTFontCopyDefaultCascadeListForLanguages` for the whole cascade; `kCTFontURLAttribute` for the path | Always present. Some language fonts are downloaded on demand and may not be on disk; skip those. |
| Linux | fontconfig, loaded with `dlopen("libfontconfig.so.1")` so it stays optional: `FcFontSort` with an `FcCharSet` and `FC_LANG` | Present on practically every desktop, but the fonts often are not: Arch and minimal installs have no CJK or color emoji font by default. The bundled fonts stay the fallback. |
| Web | none in practice | The Local Font Access API is Chromium-only and asks for permission. The web client keeps the bundled fonts. |

The fixed table for Windows, all present on a stock Windows 10 (sizes from
this machine):

| Script | File | Size |
| --- | --- | --- |
| Latin, Greek, Cyrillic, Arabic, Hebrew, ... | `segoeui.ttf` | 0.9 MB |
| Chinese (Simplified) | `msyh.ttc` | 18.8 MB |
| Japanese | `YuGothR.ttc` | 13.0 MB |
| Korean | `malgun.ttf` | 12.8 MB |
| Indic | `Nirmala.ttf` | 1.4 MB |
| Thai, Lao, ... | `LeelawUI.ttf` | 0.4 MB |
| African scripts | `ebrima.ttf` | 0.9 MB |
| Emoji | `seguiemj.ttf` | 2.0 MB |

The lookup must take the user's language. Chinese, Japanese and Korean
share codepoints (Han unification) but expect different glyph shapes, so
the same character should come from a Japanese font for a Japanese user.
DirectWrite and fontconfig both take a locale for this.

Lookups go to the OS only for characters the bundled faces lack, and their
answers are cached (character -> font), so the API is called once per new
character at most, and never for text in Latin, Greek or Cyrillic. On
Linux, fontconfig's configuration costs ~1-2 MB of heap once loaded (the
memory measurements saw 1.1 MB for its font list); it can be loaded on the
first miss rather than at start.

## 2. Switching to them, and the settings

Proposed defaults:

- **The UI font stays Roboto** everywhere, so that the client looks the
  same on every system and the layout (which assumes Roboto's metrics)
  doesn't move.
- **System fonts for characters Roboto lacks: on.** Wherever the system has
  a font for a character it is better than Unifont's 16-pixel bitmap.
  Unifont stays as the last resort, then the replacement character.
- **System emoji: on**, with the bundled sheet where the system has no
  usable emoji font (the web, Linux without one, a format we can't draw).
- A switch **"Use only built-in fonts"** for anyone who wants the old
  behaviour.

The settings show, per role (UI, Code, Emoji) and per script that has been
needed so far, where its glyphs come from: "Chinese: Microsoft YaHei
(system)", "Emoji: Segoe UI Emoji (system)", "Arabic: built-in (Unifont)".

## 3. Drawing them

stb_truetype reads TrueType outlines, CFF (OpenType `.otf`, such as Noto
Sans CJK) and collections (`.ttc`, through `GetFontOffsetForIndex`), so the
system's text fonts can be drawn with what we have. It has no hinting, so
CJK at 15 pixels on a 1x screen will be softer than in native apps; at
higher densities that doesn't matter.

It does not draw color glyphs, and every system ships its emoji in a
different format:

| System | Font | Format | Work |
| --- | --- | --- | --- |
| macOS | Apple Color Emoji | `sbix`: a PNG per glyph per size | Small: parse `sbix`, take the smallest strike at least as big as needed, decode with stb_image, scale down. |
| Linux | Noto Color Emoji (most distros) | `CBDT`/`CBLC`: PNGs | Small, the same as `sbix`. Some distros ship a COLRv1 or SVG build instead; those get the bundled sheet. |
| Windows 10 | Segoe UI Emoji | `COLR` v0 + `CPAL`: each emoji is layers of plain outlines with a color each | Moderate (~250 lines): parse `COLR`/`CPAL`, rasterize each layer with stb_truetype, tint and composite. |
| Windows 11 | Segoe UI Emoji | adds `COLR` v1 (a graph of paints with gradients) | Large. To check: whether the v0 layers are still in the file, in which case v0 is enough. |

fontstash (in Odin's `vendor`) is not worth adopting: it is stb_truetype
with a skyline packer and a chain of fallback fonts, with no shaping, no
color and an atlas that is reset when full. We have most of that already.
Its packer, which is plain Odin, is worth borrowing for the atlas below.

## 4. Shaping, right-to-left and mixed scripts

kb_text_shape (`vendor:kb_text_shape`) does Unicode segmentation
(graphemes, words, line breaks), the bidirectional algorithm, script
itemization and OpenType shaping (GSUB, GPOS), with a stack of fonts to
fall back through. It is a prebuilt C library; the web build would compile
it with emscripten like it does `stb_truetype.c`.

What it takes:

- **Layout changes shape.** `font_layout` advances a pen one codepoint at a
  time. Shaped text has to go: split into runs (script, direction, font) ->
  shape each run -> break into lines -> reorder each line for direction ->
  emit glyphs. Line breaking has to move into that pipeline, since bidi
  reordering happens per line. Shaped runs of a message are cached by
  width and zoom; a glyph is a few bytes, so a channel's worth is small.
- **A fast path.** Text that is all Latin, Greek or Cyrillic without
  combining marks (nearly all messages) keeps today's per-codepoint path.
  Only runs with complex scripts, right-to-left text or emoji sequences go
  through kb_text_shape.
- **The composer is the hardest part.** Moving the caret and selecting in
  mixed left-to-right and right-to-left text (visual vs. logical order,
  where the caret goes at a direction boundary) is the bulk of the work.
  The web client's fields get this from the browser.
- **macOS risk.** Several of Apple's system fonts for complex scripts use
  AAT (`morx`) instead of OpenType GSUB, and kb_text_shape only does
  OpenType. The same may hold for Apple Color Emoji's ZWJ sequences. Each
  font we rely on there has to be checked; where one is AAT only, prefer an
  OpenType font for that script (Noto, if installed, or a bundled one).

### The protocol

`invisible` in `proto/sanitize.odin` drops, on the server, characters that
shaping needs:

- ZWJ (U+200D): emoji sequences (families, professions, flags of
  subdivisions with tag characters).
- ZWNJ (U+200C): required in Persian and in Indic scripts to prevent a
  joining or a conjunct.
- Variation selectors (U+FE0E, U+FE0F): text vs. emoji presentation.

These have to be let through for shaping to be any use. The bidi
*overrides* and isolates (U+202A-202E, U+2066-2069) should stay out (they
are how text is disguised, "Trojan Source"); LRM and RLM (U+200E, U+200F)
are harmless and useful in mixed text. Clients without shaping (the old
ones, the web if it doesn't get it) draw such text the way they do today,
with the joiners invisible.

## 5. Memory

The rule that makes system fonts cheap: **map the font files, don't read
them**, and **rasterize glyphs when they are first drawn, not up front**.

- A mapped file's pages are clean and shared with the system's file cache.
  They are not private memory (what `memory.md` measures and a task
  manager shows), the system drops them when it needs the room, and only
  the pages we touch are resident at all: the character map and the
  outlines we draw. So a 19 MB `msyh.ttc` or a 180 MB Apple Color Emoji
  costs the client close to nothing until it draws from them.
- Don't build per-face tables over the whole BMP for system fonts, as
  `face_init` does for Roboto. Look a character up when it is first needed
  and cache the answer.
- **One glyph cache for all fonts**: keyed by (font, glyph, size), in alpha
  pages of 1024x1024 (1 MB each), filled with a skyline packer, at most 2-4
  pages, evicting the least recently used page when full. *Estimate*: a
  page holds ~2500 CJK glyphs at 15 px on a 1x screen, ~650 at 2x; a
  screen of text uses a few hundred.
- **Emoji the same way**, in RGBA pages: an emoji drawn at 18 px on a 2x
  screen is ~40x40x4 = 6 KB, so a 1 MB page holds ~150. *Estimate*: 1-4 MB
  instead of the sheet's ~22 MB of video memory, for all ~3700 emoji
  including skin tones, flags and ZWJ sequences.
- **Dropping skin tones saves nothing** in this model: a variant costs
  space in the font file (the system's, mapped) and only takes a slot once
  someone uses it. It only matters for the bundled sheet, where every
  variant is a cell.
- **An atlas of common Chinese characters is not needed** for system fonts:
  the lazy cache only ever holds what is on screen, which is less than any
  "common" set. A subset is only a way to make a *bundled* CJK font
  smaller (GB 2312 / JIS level 1, a few MB), and Unifont already covers the
  BMP in 877 KB.
- **The cost is time on first draw**: *estimate* 20-50 µs to rasterize a
  CJK glyph with stb_truetype, more to decode and scale a PNG emoji. A
  channel of new CJK text, or scrolling the emoji picker, could stutter.
  Rasterize at most a budget per frame and draw the rest the next frame
  (they take their space already, like emoji do while the sheet decodes).
- **To measure**: what kb_text_shape allocates per font. `LoadFont` turns a
  font's GSUB and GPOS into structures of its own; for Segoe UI or Noto
  Sans CJK that may be large, and may decide whether shaping fonts are
  loaded only when a run needs them.

## The emoji artwork, and what Mattermost does

The bundled sheet is Apple's artwork: `tools/emoji.py` cuts it from a Linux
build of Apple Color Emoji, and `assets/AppleColorEmoji.ttf` (18.8 MB) is in
the repository.

Mattermost does the same thing. Its `make_emojis.mjs` (webapp, build time)
copies the 64 px sprite sheet from the npm package `emoji-datasource-apple`
(iamcal's emoji-data), with three emoji Apple lacks taken from
`emoji-datasource-google`, and its CSS draws every emoji from that sheet
with `background-position`. The browser's own emoji font isn't used for
them. Skin tones are in the sheet.

emoji-data's own README, however, says that the Apple images, "Copyright ©
Apple Inc., are not licensed for commercial usage". Its other sets are
licensed: Google's Noto Emoji under Apache 2.0 (the font itself under the
OFL), Twitter's Twemoji under CC BY 4.0 (with attribution). That Mattermost
ships Apple's set is no indication that it is allowed; nothing in what was
read of their notices mentions it.

There is no non-commercial permission either: "not licensed for commercial
usage" is emoji-data's description, not a licence. The only licence for the
font is the one it comes with on macOS, for use on that Mac, and committing
an extracted copy and shipping a sheet cut from it is redistribution
whether or not anyone pays for it.

So with system emoji in place, the bundled fallback (the web, Linux without
an emoji font) is better made from artwork that may be shipped. On macOS
users still see Apple's emoji, from their own system, and the Apple font
can leave the repository.

### Blob emoji for the bundled set

Google's older "blob" design (Android up to 7.1, replaced in 2017) is a
good fit for the fallback: it is from the `googlefonts/noto-emoji`
repository, whose fonts are under the SIL OFL 1.1 and whose images and
tools are under Apache 2.0, and nothing found puts the blob artwork under
other terms. Both allow redistribution, commercial included; we would add
the licence and an attribution to `src/client/licenses`.

The original blob font stops at about Emoji 4/5 (2016-17). That matters
more than it seems: `tools/emoji.py` keeps only the emoji the font has a
picture for and writes `proto/emoji_table.odin`, the table both client and
server use for shortcodes and the picker, in the same run. With the old
font every emoji from 2017 on would leave the table for every client,
including those that draw system emoji. Using it would mean separating the
table (gemoji's list) from the sheet (whatever the font has) in the script,
with missing pictures drawn as nothing or from another set.

**Blobmoji** (`C1710/blobmoji`) avoids that: a community fork that kept
drawing new emoji in the blob style on top of Noto's sources, under the
same licences, up to Emoji 15.0. It was archived in June 2026, which
doesn't matter for a sheet that is made once and committed. It is built
from Noto's font template, so it is very likely CBDT like Noto Color Emoji
and readable by `tools/emoji.py` as it is; not checked (the release's file
name and format weren't visible). Running the script on it settles that.

The sheet costs the same memory with any artwork (1012 cells of 64 px);
the blobs' flatter colors may make the WebP somewhat smaller, which only
affects the download and the binary.

## Order proposed

1. **System fonts for characters the bundled faces lack**, without shaping:
   discovery per OS (the fixed table first on Windows), mapped files, the
   lazy glyph cache, and the list in the settings. Every platform gains
   coverage, and it is self-contained.

   *As built:* `render/sysfont.odin` (shared), `sysfont_native.odin`
   (mapping a file, finding a collection's font by PostScript name),
   `sysfont_windows.odin` (the fixed table, the user's CJK font first),
   `sysfont_darwin.odin` (CoreText: `CTFontCreateForString`, then
   Helvetica's cascade list), `sysfont_unix.odin` (fontconfig through
   `dlopen`, `FcFontSort`), `sysfont_web.odin` (nothing). A character is
   looked up once, after the bundled faces and the emoji sheet and before
   Unifont; a font that has no outline for it (an emoji font) is skipped.
   Unifont's slots became one shelf-packed atlas per font
   (`glyph_atlas.odin`) that holds both Unifont's and the system's glyphs.
   The switch is "Use the system's fonts" under Settings > User interface,
   on by default, with the fonts used so far listed under it; turning it
   lays the chat out again (`Msg_Layout.fonts`). Found on the way: macOS's
   PingFang is a variable font with CFF2 outlines, which stb_truetype can't
   read, so Chinese there comes from the next font in the cascade list
   (Hiragino Sans). Checked by rendering sample text in eight scripts on
   Windows 10 and macOS 27 (the render tests and a scratch program); the
   fontconfig path has only been type-checked, not run.
2. **System color emoji**: `sbix`, `CBDT`, `COLR` v0, in the lazy RGBA
   cache, with the bundled sheet (remade from Blobmoji) as the fallback.
   Remaking the sheet can also happen first, on its own, since it only
   changes `tools/emoji.py`'s input. Saves most of the emoji's video memory.

   *As built:* `render/colorfont.odin` reads `cmap`, `sbix`, `CBDT`/`CBLC`
   and `COLR` v0/`CPAL` itself (stb_truetype only rasterizes COLR's
   layers), and draws an emoji into a square RGBA tile at the size it is
   shown, fitted like the sheet's. `sysemoji_native.odin` picks the font
   (Segoe UI Emoji on Windows, whatever the system offers for 😀 elsewhere)
   and fills each font's RGBA atlas (`Font.emoji`) as emoji are drawn. Only
   the table's emoji are drawn this way, in the space they always take, so
   switching ("Use the system's emoji" under Settings > User interface)
   moves no text; an emoji the font lacks, or one drawn while the atlas is
   full, comes from the sheet. The sheet is Blobmoji v15.0: measured
   against today's 2.16 MB Apple sheet (1005 emoji), the same 1005 came to
   2.03 MB from the 2017 blob font and 2.04 MB from Blobmoji; their full
   sets to 2.18 MB (1083) and 2.78 MB (1377, which needs a taller sheet at
   64 pixel cells). It is Blobmoji's full set in 48 pixel cells, 42 by 42
   in the same 2048 pixel sheet: 1375 emoji (© and ® stay text), 1.88 MB,
   370 more in the shared table. `AppleColorEmoji.ttf` left the
   repository. Checked by rendering on Windows 10 (COLR), macOS 27 (sbix)
   and with Blobmoji.ttf for CBDT; not run on Linux.
3. **Shaping and bidi with kb_text_shape**, together with the change to
   `sanitize.odin` on the server. Emoji sequences and skin tones (and
   offering them in the picker) come with this step.

   *As built* (for text that is shown; the composer and sequences are
   steps 4 and 5): kb_text_shape v2.21 is in `deps/thirdparty`, compiled
   by `build.sh`/`build.bat` behind `src/client/shape/yap_shape.c`, which
   keeps its structs on the C side and gives Odin flat runs of glyphs
   (fonts by number; runs split at a change of direction, script or font;
   glyphs of a right-to-left run already in visual order). It uses the
   direct API, so each character keeps the font `find_glyph` picks (a mark
   or joiner goes with the character before it), and segments with
   `kbts_BreakAddCodepoint`: `kbts_BreakEntireStringUtf32` returned stray
   entries between the real ones. `render/shape_native.odin` shapes only
   strings that need it (`needs_shaping`: RTL, joining and Indic scripts,
   combining marks, joiners; not Latin, Greek, Cyrillic, CJK or emoji),
   puts the runs of the line in visual order (two levels, plus numbers
   after RTL text going with it), caches each shaped string while frames
   use it, and rasterizes shaped glyphs into the fallback atlas by font and
   glyph index. Characters without a shaping font (Unifont, emoji) keep
   their old drawing, in the reordered place. Rich text's pieces are each
   shaped and ordered on their own, and RTL lines stay left-aligned.

   The composer and text boxes lay text out in logical order (a flag in
   the font handle): left-to-right runs are shaped, right-to-left ones
   drawn letter by letter as typed, so the caret, placed by the width of
   the text before it, stays right. Selecting text that is shown in visual
   order still highlights by logical widths. (Both replaced in step 4.)

   Messages keep U+200C/200D and U+200E/200F/061C (`sanitize_message`);
   names and other single lines keep none, so that a name can't pass for
   another; the embeddings, overrides and isolates go everywhere.

   macOS draws Arabic with Geeza Pro, whose rules are AAT only, and its
   fallback list's next font with OpenType rules is Noto Nastaliq Urdu.
   For scripts that join, a font with a `GSUB` table is now taken first,
   and on macOS SF Arabic (then Tahoma) is offered right after CoreText's
   choice. The web client doesn't shape (kb_text_shape isn't built with
   emscripten yet).
4. **Editing in visual order**: the composer and text boxes lay text out
   like the rest (shaped right-to-left runs, in visual order), with the
   caret placed and moved by grapheme in visual order, hit-testing and
   selection over runs, and the same for selecting shown text.

   *As built:* the logical-order mode of step 3 is gone; the composer,
   text boxes and messages are all laid out the same way. For a line that
   is shaped, `render.text_spans` gives each character's left and right
   edge and direction (characters of one cluster share its glyphs' width),
   and `ui_bidi.odin` works from those. Each place in a line has one spot
   its caret is drawn at: the line's start and end at its edges (start on
   the left of a left-to-right line, end on its right, mirrored for a
   right-to-left one), any other place at the trailing edge of the
   character before it. A click lands on the place drawn nearest to it,
   a selection is the stretches its characters cover, and Left and Right
   go to the place drawn next on that side (on to the next or previous
   line at a line's end; through the text with Ctrl and to drop a
   selection). The text area (`area_x`, `area_hit`, `area_ranges`), the
   spell checker's underlines, the text boxes (`text_box_raw`, microui's
   text box with these, and without them for a password box) and selecting
   messages (`select_line`, run by run as rich text is drawn) use them;
   lines that aren't shaped keep the old prefix widths.

   Checked in the app with "abc שלום 123": the first version placed the
   caret at a line's end after "3" and clicks at the far right before "1",
   and Right bounced inside the Hebrew word, because clicks and carets
   followed different rules; the single rule above came out of that. The
   same test showed `123"` moving with the Hebrew word: levels are now
   worked out per character (`char_levels`), so numbers after RTL text go
   with it but punctuation after the last digit belongs to the line again.
   What is left is listed under "Caret: what's left" below.
5. **Emoji sequences**: keep U+200D, skin tones, flags and tag sequences
   in emoji, shape them with the system's emoji font (its ligatures), key
   the color atlas by glyph, and offer skin tones in the picker. The sheet
   draws a sequence as its parts.

## Caret: what's left

What remains of editing right-to-left and shaped text after step 4,
roughly in the order it would be noticed. 1 and 2 are small and come up
in everyday editing, so they go first; 3 is its own change; 4 and 5 can
wait until someone needs them.

1. **Moving by cluster.** Left and Right step one character at a time,
   but a cluster (a Devanagari conjunct such as क्ष, three characters;
   a letter with combining marks; Thai with its tone marks) is drawn as
   one glyph, and `text_spans` divides its width among its characters, so
   the caret stops at made-up places inside it. It should step over the
   whole cluster. kb_text_shape's segmentation marks where graphemes start
   (`KBTS_BREAK_FLAG_GRAPHEME`): `yap_shape.c` can return those breaks with
   the runs, `Char_Span` can mark the characters a grapheme starts at,
   `bidi_step` and the caret places can skip the others, and a click can
   land only at grapheme boundaries. Backspace keeps deleting one
   character at a time inside a cluster, as other editors do.
   Done when: Right over "क्ष" takes one press, a click inside it lands
   before or after it, and Shift+Right selects it whole.

   *Done:* `ys_shape` fills a `grapheme_start` array from the break flags,
   `Shaped.joined` and `Char_Span.joined` mark the characters that continue
   the grapheme before them, and `caret_stops` leaves out the places in
   front of those, which `bidi_step` and `bidi_offset_at` both go by.
   (`yap_shape.lib` has to be rebuilt after pulling this: delete it.)

2. **Ctrl+Left/Right by word along the screen.** Word jumps still follow
   the text (`textedit` `.Word_Left`/`.Word_Right`), so inside Hebrew or
   Arabic Ctrl+Right moves the caret to the left. In a shaped line they
   should go to the next word boundary on that side of the screen: of the
   caret places (`caret_stops`), those at the start or end of a word
   (`area_word`'s classes), nearest in that direction, and on to the next
   line at the end, as the plain arrows do. The same in text boxes.
   Done when: Ctrl+Right in "abc שלום עולם 123" goes "abc" → the word
   right of it on the screen → … → the line's right end, never backwards.

   *Done:* `bidi_step` takes the line's text for Ctrl and then only stops
   at places where a word starts or ends (`char_class`, shared with
   `area_word`) or at the line's ends; the text area and text boxes pass it.

3. **Right-aligning right-to-left lines.** A line whose first strong
   character is right to left (`Char_Span.line_rtl`, `Shaped.rtl`) is
   still drawn from the left edge, in messages and in the composer. It
   should be drawn against the right edge of its column. That is layout
   rather than caret work: the timeline's and the text area's line
   drawing (and `select_line`'s `pos`) shift such a line by the room left
   over; the caret, clicks and selection follow, as they are relative to
   the line's start. Text boxes may stay left-aligned. To decide: whether
   a whole message aligns by its first line or each line by its own.
   Done when: a Hebrew message and a Hebrew line in the composer sit at
   the right, and clicking and selecting in them still land right.

   *Done, each line by its own direction:* `line_is_rtl` (ui_bidi.odin)
   tells whether a line is shaped and right to left. `rich_text` moves such
   a line's `pos` by the room left over (not in code blocks or table cells),
   and the text area keeps it as `Area_Line.shift`, which `area_x`,
   `area_hit`, `area_ranges` and the drawing all include.

   Typing in Hebrew made the text shuffle by a pixel: glyphs were placed
   from the line's start, so each one's rounding changed with the line's
   width as letters were added on the left. `font_layout` now places a
   right-to-left line's glyphs from its right end (`x` plus its measured
   width rounded up, which is where the callers align it).
   `text_spans` adds the same rounding-up room to such a line's
   characters, so the caret, selection and spell-check squiggles stay on
   the glyphs (the squiggles used to move as the line's width changed).

4. **A two-sided caret at direction changes.** Where the direction
   changes, one place in the text can be shown in two spots: the place
   before ש in "abc שלום 123" is shown after "abc ", where Latin typed
   there goes, though Hebrew typed there goes to the far right of the
   word. Editors such as Chrome keep a side with the caret (its affinity)
   and let the arrows switch it. This adds state to the caret (the place
   and the side) in the text area and text boxes; to do only if the
   single spot turns out to confuse in practice.

5. **The web client.** It neither shapes nor reorders (`shape_web.odin`);
   its composer is the page's own field, which the browser handles, but
   messages show right-to-left text in typing order. kb_text_shape would
   need to be compiled with emscripten (`web/build.sh`, as
   `stb_truetype.c` is) and bound like `wstbtt`; then everything above
   applies there too, with Unifont as the only font for most scripts.

## Not covered

Nothing here has been prototyped. Not checked: whether Windows 11's Segoe
UI Emoji keeps `COLR` v0, which macOS fonts are AAT only, kb_text_shape's
memory per font, and the real cost of rasterizing on first draw.
