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
| 4 | Bigger channel list, more spacing, bigger on phones | M | - | done (2026-10-21) |
| 5 | Icons for Add, Back and Next | S | - | done (2026-10-21) |
| 6 | Spinners for what is loading | S | - | done (2026-10-21) |
| 7 | Smooth scrolling | M | - | done (2026-10-21) |
| 8 | Smaller polish (see the list at the end) | S each | 1 | 4 of 5 done (2026-10-21) |

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

*As built:* `style_apply` (`ui.odin`) sets microui's style every frame,
before `mu.begin`: padding 6, spacing 6, size 80x14 (rows 26 px, from
20), and on a phone padding 8, spacing 8, size 80x28 (rows 44 px). A
phone (`ui.compact`) is a window narrower than `NARROW_LAYOUT` beside the
rail, or a touch screen once it has been used (`ui.touched`, set when
`ui_touch_web.odin` queues an event), on every screen, not only the
session's.

- The channel list is in `render.LIST_FONT` (`Font_Kind.List`, the UI's
  font at `LIST_ZOOM` 1.15, its atlases made once it is drawn with, like
  `Preview`'s). Its rows are the text and 6 px above and below, at least a
  control's height (33 px, 44 on a phone), and 2 px apart.
- `icon_button_w` and `composer_button_size` make icon buttons and the
  composer's buttons square with the rows on a phone (otherwise 30 and 26
  as before). The rail and the drop overlay keep `ICON_BUTTON`; the user
  menu narrows its icons where all of them don't fit its width.
- The status line above the chat (typing, notices) is a text line tall,
  not a control's.

The tests keep microui's own style (they don't call `style_apply`), so
their numbers didn't change; `test_style_for_phones` checks the sizes.
Looked at off-screen at 1000 and 420 px wide: the session screen, the
channel list and a channel's menu, settings, a server's channels, Join a
channel, DMs. Not seen: a real phone (touch), and scales other than 1.

Then less room on phones, which left too little for the messages: rows
40 px (padding 6, spacing 4), the timeline spaced as microui's own
(`COMPACT_MESSAGE_PADDING` 5, `COMPACT_MESSAGE_SPACING` 4), and the
composer one line tall to start with. At 420x700 the messages got 431 px
instead of 365.

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

*As built:* `Plus`, `Back` and `Next` in `render.Icon`, drawn with the
tick's stroke (`chevron`). The back buttons and the pager are
`icon_button`s with the hints they had, the purge page's arrows got hints
("Conversation before", "Conversation after"), and the rail's join button
draws the plus over its disc, as the DM button does its envelope.
`people_list` and `people_finder` take an optional `icon` that replaces
the button's word (which becomes its hint): the two "Add" finders use
`.Plus`; "Take out", "Take it" and "Give" stay words. Looked at
off-screen: the rail, the purge page, a phone's back button, the members
window's finder.

## 6. Spinners for what is loading

The renderer only draws upright quads, so a spinner is an arc baked into
the icon atlas in about 12 steps, shown one after another. While one is on
screen it asks for a frame every `ANIMATION_FRAME` (`ui_redraw_in`), and
only then. It replaces "Loading messages...", "loading picture...",
"loading image..." and the like (`ui_timeline`, `ui_images`), keeping the
words where they say more than a spinner would.

*As built:* `render.Icon.Spinner` is the first of `SPINNER_STEPS` (12)
slots at the end of the icon atlas (`ICON_SLOTS`, `spinner_id`): a ring
with a quarter missing, turned 30 degrees clockwise per step, in the
tick's stroke. `spinner` (`ui.odin`) draws the step the clock is at, a
turn a second, and asks for a frame at the next step (`ui_redraw_in`), so
12 a second rather than every `ANIMATION_FRAME`, and none when it is
clipped away; `spinner_row` is one in a row of its own. They replace:
the timeline's "Loading (older) messages/replies...", a DM's "Loading
messages...", the pins' and members' "Loading...", "Waiting for the
channel list...", and "loading picture..." / "loading image..." in
pictures and the viewer. A picture the server no longer has (`.Gone`)
now says "broken image", where it used to say "loading picture..."
forever. Words stay for connecting, uploading, sending, the camera's
"Waiting for the picture..." and "Loading the message replied to...".

Seen off-screen through a UDP proxy that delays every packet 0.25 s: the
channel list's and the timeline's spinners while connecting. Idle after
loading: 1% of a core, as before.

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

*As built:* `scroll_callback` keeps whole notches (`WHEEL_NOTCH`, 30 px)
in `ui.scroll_left`; fractions of one (touchpads) still go to microui as
they come. `scroll_step`, before each frame's layout, hands microui the
share that has run out: what is left shrinks by e every `SCROLL_EASE`
(50 ms), in whole pixels, so a notch ends exactly 30 px away, in about 11
frames; it asks for frames every `SCROLL_FRAME` (1/60 s) while any is
left. The native loop now wakes for a frame asked for by a time
(`ui_redraw_at`) instead of at most every 1/30 s, which also keeps the
spinners on time. The viewer's wheel zoom follows the spread-out input,
so it zooms smoothly too. The wheel over a message's bar
(`ui_message_bar.odin`, a window of its own) scrolls the timeline under
it: while microui takes the bar as under the pointer, the bar makes that
timeline's panel the scroll target, which also covers the frames in which
the bar moves with the message under the pointer.

Seen off-screen in a channel of 60 messages: each notch moved the text
exactly 30 px (24-25 px in a shot taken right after it), up and down;
back at the end, a new message was followed. Idle afterwards is the same
as without the change (28-31 ticks in 10 s, measured against a build of
`better-ui`).

## Smaller polish, later

- Flat buttons elsewhere: no border, a background only under the pointer;
  an accent ring on the focused text box.

  *As built:* buttons have no border, only a fill (`render.draw_frame`;
  `icon_button` draws its own, rounded). Fully flat icon buttons (a
  background only under the pointer) were hard to tell for buttons, so
  only the composer's stay so (`UI.flat_buttons`, inside its box); the
  button colors stand out a little more from the window (light 214 on
  246, dark 80 on 50). A focused text box (`.BASE_FOCUS`) is drawn by
  `draw_frame_themed` (`ui.odin`, microui's `draw_frame`) with a 2 px
  ring in `theme.accent`: its border and a line inside it, so nothing
  reaches past the box.

  *As built:* one more tile below the corners in each font atlas
  (`Corner_Tiles.shadow`, `corners.odin`): the corner of a window's
  rounded shape blurred over `SHADOW_BLUR` (10), dark from a little
  inside the edge and about half at it. `push_shadow` draws a shadow
  from it in 9 quads (the tile mirrored at the corners, its last column
  or row stretched along the edges, the middle solid), `SHADOW_DROP` (2)
  lower than the window. `draw_frame_themed` draws it before the frame of
  every window over the main window (menus, popups, the message bar, Join
  a channel and the like), in `theme.shadow` (black, alpha 55 light, 120
  dark).
- Thinner scrollbars that fade out when nothing scrolls.

  *As built:* `ui_scrollbars.odin`. `draw_frame_themed` hands microui's
  scrollbar tracks and thumbs to `scrollbar_frame`, which keeps each
  container's last scroll position (`UI.scrollbar_fades`). The thumb is a
  `SCROLLBAR_THIN` (4) pill at the strip's outer edge, `SCROLLBAR_WIDE`
  (8) over a faint track with the pointer on the strip. It shows for
  `SCROLLBAR_SHOWN` (0.8 s) after the container scrolled and fades out
  over `SCROLLBAR_FADE` (0.3 s), asking for frames only for that; one that
  hasn't scrolled since it was first drawn shows none until the pointer
  is on it. The strip (`style.scrollbar_size`) is still what it takes and
  where it is grabbed, so no layout changed. The text area's scrollbar is
  thin too, and always shown while it has one.
- Placeholders the size of a picture while it loads, where the size is
  known, so the timeline doesn't jump.

  *As built:* the timeline didn't jump (a picture's row is
  `PREVIEW_HEIGHT` either way), but the placeholder was the whole row
  until the picture's shape showed. Messages' files carry no picture
  size, so it can't be known before the first decode; after that,
  `UI_Images.sizes` keeps it (up to `MAX_KNOWN_SIZES`, cleared on a
  server switch), and a picture decoded again (past
  `MAX_IMAGE_TEXTURES`, or back in a channel) waits in a box of its own
  shape, with its spinner. `image_size` answers from it too (the chip
  preview).
- Typing dots that move, and short fades on hover (state per control
  id).
