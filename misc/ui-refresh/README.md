# UI refresh: plan

Making the client look more modern within microui: rounder, roomier, with
icons where there are still letters, and a little motion where something is
loading. All of it is client only, on the `better-ui` branch, in the order
below. Each item is its own commit; the item's section is the plan, and what
turned out differently is written under it when it's done ("*As built:*"),
as in `misc/next`.

Sizes as in `misc/next`: S up to about 300 changed lines, M up to 1000, L up
to 2500.

| # | Change | Size | Depends on | Status |
| --- | --- | --- | --- | --- |
| 1 | Rounded corners: controls, panels, floating windows | M | - | done (2026-10-21) |
| 2 | Idle redraws: image keys that collided | S | - | done (2026-10-21) |
| 3 | The composer's buttons inside its box | M | 1 | done (2026-10-21) |
| 4 | Bigger channel list, more spacing, bigger on phones | M | - | next |
| 5 | Icons for Add, Back and Next | S | - | |
| 6 | Spinners for what is loading | S | - | |
| 7 | Smooth scrolling | M | - | |
| 8 | Smaller polish (see the list at the end) | S each | 1 | ideas |

Why this order:

- **1 first**: buttons, badges and the composer all build on the rounded
  rect, and it changes how everything looks, so the rest is judged
  against it.
- **2** wasn't planned: it turned up when checking that an idle client
  doesn't draw, and was fixed before going on.
- **3 → 4 → 5**: what people look at most, then the layout everywhere,
  then the leftover letters. 4 touches sizes all over, so it goes before
  anything else that adds controls.
- **6, 7 last**: they are the only ones that make the client draw when
  nothing changed (only while something loads or scrolls), so they need
  the most care that the client stays idle otherwise (see 2).

How to check a change on Windows without touching the desktop: build with
`build.bat`, start `bin\yap.exe` and capture its window with `PrintWindow`
(not by bringing it to the front, which captures whatever is in front
instead). Posted mouse messages don't reach it, so interaction is checked
with tests (as `ui_composer_test.odin` does) or by hand.

## 1. Rounded corners

Rounded rects drawn from quarter-disc and quarter-ring tiles, rasterized at
the display's density for every radius up to `ROUND_MAX` (12 logical px)
into the bottom of each font atlas, below its white texels. A rounded rect
is then drawn from the same texture as the text around it: up to 7 quads
and no draw call of its own, and no shader changes in any of the backends
(D3D11, Metal, GL, WebGL).

*As built:* `render/corners.odin` makes the tiles. `render.draw_rounded` and
`draw_rounded_border` emit icon commands whose ids
(`ROUNDED_ICON_BASE`..) carry the shape, the corners and the radius, and
`push_rounded` draws them, snapped to physical pixels like `push_border`.
`draw_frame` rounds:

- buttons and text boxes (`CONTROL_RADIUS`, 4);
- panels and floating windows (`WINDOW_RADIUS`, 6), with a window's title
  bar rounded at the top, filled out to the border's outer edge and the
  border drawn over it again (otherwise the two curves each cover part of
  the pixels where they meet, and the window's color shows through);
- scrollbars, as pills.

The main window and the rail (zindex below 0) stay square. List rows'
highlights, badges (pills), the hint and the drop and chip-preview boxes
are rounded too. Fills under a border go out to the border's outer edge for
the same reason as the title bar.

Not seen on screen: a floating window's title bar (no window could be
opened from outside), and scales other than 1 (covered by tests only).

## 2. Idle redraws

An idle client drew about 60 frames a second (about 20% of a core). Texture
keys were a blob id or a hash with a bit per kind OR'd in. A server icon's
key is a hash of the server's address, and when it had the viewer's bit set
the cache took it for the viewer's full-size copy, dropped it every frame
and decoded it again, and each decode woke the UI. The icon never showed
either.

*As built:* `Image_Key` (kind, `full` for the viewer's copy, id) in
`ui_images.odin`, used everywhere textures are kept. Idle is now about 1.4%
of a core: the loop's 30 wakes a second without drawing, and the
connection's.

## 3. The composer's buttons inside its box

- At least two lines tall, across the conversation's width.
- A strip along its bottom for the buttons: attach, emoji, preview (and a
  DM's file), at the bottom right, without a frame or background except
  under the pointer.
- The send button grey until there is something to send, then in the
  accent color.

*As built:* `Text_Area` has `min_lines` and `footer` (the strip), which the
text, its scrollbar and the I-beam keep out of. Pressing in the strip
doesn't move the caret (`footer_press`). `composer_buttons` lays the
buttons out over the strip and draws them flat (`ui.flat_buttons`),
`composer_send_button` is the send button, `composer_buttons_end` ends
them. The theme has `accent`, `accent_hover` and `accent_text`. The preview
fills the part above the strip. Same for threads and DMs. The box is about
108 px tall when empty (`COMPOSER_LINES`, `COMPOSER_BUTTON`,
`COMPOSER_INSET` in `ui_chat.odin`). Tests in `ui_composer_test.odin`.

Two fixes after: the box scrolls as if it already had the height it is
growing to, so a new line no longer shows its scrollbar for a frame
(and scrolls the text) before the box grows; and its scrollbar is drawn
with `draw_frame`, as pills like the panels'.

## 4. Bigger channel list, more spacing, bigger on phones

- The channel list in a larger font, with more padding per row. A
  `Font_Kind` of its own with a zoom, like `Preview`'s (one more atlas),
  rather than bigger text everywhere.
- More spacing generally: microui's style is still its default (padding 5,
  spacing 4, `size` 68x10), set in `theme_apply` along with the colors.
- More again on phones (`ui.narrow` or touch): touch targets of about
  44 px.

What makes it more than a change of numbers: sizes written out in the
layout (`ICON_BUTTON :: 30`, `LINE_HEIGHT :: 18`, widths per screen, rows
sized as `size.y + 2 * padding`), so every screen needs a look afterwards,
and tests that measure layouts (`ui_chat_preview_test`,
`ui_text_area_test`, the composer tests) may need new numbers.

## 5. Icons for Add, Back and Next

Three more icons in `render/icons.odin` (distance functions, like the
others): a plus and two chevrons. They replace the text labels:

- `"<"`: the back buttons (`ui_account`, `ui_buddies`,
  `ui_channel_settings`, `ui_channels`, `ui_roles`, `ui_settings`), the
  pager (`ui_pager`) and the purge pages (`ui_manage`);
- `">"`: the pager and the purge pages;
- `"+"`: the rail's join button (`ui_servers`), and the "Add" of the people
  finders (`ui_channel_settings`, `ui_manage`) where an icon reads better
  than the word.

## 6. Spinners for what is loading

The renderer only draws upright quads, so a spinner is an arc baked into
the icon atlas in about 12 steps, shown one after another. While one is on
screen it asks for a frame every `ANIMATION_FRAME` (`ui_redraw_in`), and
only then. It replaces "Loading messages...", "loading picture...",
"loading image..." and the like (`ui_timeline`, `ui_images`), keeping the
words where they say more than a spinner would.

## 7. Smooth scrolling

The wheel's notches go to microui as 30 px jumps (`ui.odin`,
`mu.input_scroll`), applied in full in the next frame. Spreading a notch
over a few frames (eased, asking for frames with `ui_redraw_in` while
there is some left) makes every panel scroll smoothly without changing
microui. Touchpads already send small steps and stay as they are.

The timeline keeps its own scroll position (a message and how far into it,
`ui_timeline.odin`, from `cnt.scroll.y - st.scroll`), so jumping to a
message and keeping to the end must be checked with the spread-out input.
Scrolling wants 60 frames a second while it moves (`ANIMATION_FRAME` is
30).

## Smaller polish, later

- Flat buttons elsewhere: no border, a background only under the pointer;
  an accent ring on the focused text box.
- Shadows under popups, from blurred corner tiles the same way as 1.
- Thinner scrollbars that fade out when nothing scrolls.
- Placeholders the size of a picture while it loads, where the size is
  known, so the timeline doesn't jump.
- Typing dots that move, and short fades on hover (state per control
  id).
