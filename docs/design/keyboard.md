# Keyboard: Tab navigation and a command palette

The goal: the client can be used without a mouse.

- **Tab / Shift+Tab** move a visible focus through the controls on screen;
  Enter or Space presses the focused one.
- **A command palette** (Ctrl+Space) lists what can be done, filtered by
  what is typed, and runs the chosen command. It also switches channels,
  servers and conversations.

Sizes as in [next.md](next.md).

| # | Change | Size | Status |
| --- | --- | --- | --- |
| 1 | Keys: Shift+Tab, Space, the palette's key | S | done |
| 2 | The focus ring: `UI_Nav`, `nav_control`, the shared widgets | M | done |
| 3 | Tab inside popups, scrolling into view, keys taken by others | M | done |
| 4 | The palette with static commands | M | |
| 5 | Dynamic entries (channels, servers, buddies) and recent first | M | |
| 6 | The rest of the controls, arrow keys inside lists | L | |

1–3 are Tab navigation, 4–5 the palette. Only phase 1 is shared, so after it
the two halves can be built side by side.

## Where things are today

- The UI is microui (`vendor:microui`). `mu.update_control` sets
  `ctx.focus_id` on a press over a control, and drops it again in the next
  frame without the mouse button down unless the control passes
  `HOLD_FOCUS`. Only text boxes ([ui_text_area.odin](../../src/client/ui_text_area.odin),
  `mu.textbox_raw` behind `text_box`) hold it. So `focus_id` is "the control
  being clicked" for buttons and "the text box being typed in" for boxes; it
  can't carry a keyboard focus for a button.
- Buttons submit on `ctx.mouse_pressed_bits == {.LEFT} && ctx.focus_id == id`
  (`icon_button`, `stable_button`, `checkbox`, the dropdown) or on
  `hover_id == id` (`list_row`), right after `update_control`.
- Shared widgets in [ui_widgets.odin](../../src/client/ui_widgets.odin):
  `icon_button`, `stable_button`(`_hint`), `list_row`, `checkbox`,
  `tab_button`, `choice_button`, `confirm_button`; `dropdown` in
  [ui_dropdown.odin](../../src/client/ui_dropdown.odin); `text_box` and
  `password_box` in [ui_text_box.odin](../../src/client/ui_text_box.odin);
  `text_area` for composers. Besides these there are 29 plain `mu.button`
  calls (9 in ui_account.odin, 4 in ui_manage.odin, …) and about 15 custom
  `mu.update_control` sites (chat rows, the voice panel, the roles grid,
  user rows, the title bar's buttons, …).
- `key_callback` ([ui_window.odin](../../src/client/ui_window.odin)) turns
  keys microui has no name for into `UI.keys: bit_set[Extra_Key]` (Up, Down,
  Tab, Escape, Newline, and the composer's markdown keys), cleared after each
  frame. Tab drops its modifiers, so Shift+Tab is Tab. Space reaches microui
  only as text, through `char_callback`.
- Whoever uses a key first takes it out of the set:
  `completion_keys` ([ui_completion.odin](../../src/client/ui_completion.odin))
  takes Up, Down, Escape, Tab and Enter while its list is open, before the
  composer sees them. The message menu, the image viewer, the camera
  preview and voice dragging look at Escape.
- Overlays: `search_window` ([ui_search.odin](../../src/client/ui_search.odin))
  is a `mu.begin_window` placed once when it opens (`placed`), brought to
  the front, with `hover_root` set to it. The completion list, the forward
  dialog and dropdown popups are similar. Work that would change the layout
  mid-frame is put off until after the frame (`attach_pick`).
- Global hotkeys ([ui_hotkeys_native.odin](../../src/client/ui_hotkeys_native.odin))
  have two actions, Mute and Deafen; `set_muted` is in
  [ui_sessions.odin](../../src/client/ui_sessions.odin). Pages are
  `UI.page` (Main, Settings, Buddies).
- The headless client's slash commands
  ([headless/commands.odin](../../src/client/headless/commands.odin))
  cover much of what a palette would offer: /view, /join, /leave,
  /notify, /subscribe, /create, …

## Decisions

Each has a recommendation; change any you disagree with.

**D1 — Our own focus, next to microui's.** Recommended: `UI_Nav.focus`, an
`mu.Id` kept across frames, separate from `ctx.focus_id`. Giving buttons
`HOLD_FOCUS` instead would change how every click behaves (focus would stay
on a button until a press elsewhere). When the keyboard focus lands on a
text box, `ctx.focus_id` is set too (`focus_at`), since that is what makes
it take typing.

**D2 — Hook the widgets, not microui.** Recommended: one call,
`nav_control`, after `update_control` in each of our widgets. The vendor
package stays as it is. Patching `update_control` itself would catch every
control, but would mean keeping a copy of microui, and some controls (chat
rows, the image viewer's picture) should not be stops.

**D3 — Focus shown only after the keyboard is used.** Recommended: like the
web's `:focus-visible`. Tab shows the outline; a mouse press hides it and
clears the focus. Clicking doesn't move the keyboard focus.

**D4 — Order.** Recommended: the order controls are drawn in, which is
mostly reading order (rail, channels, chat, users). If that turns out wrong
somewhere, items can be sorted by a group number before their draw order.
F6 jumps between the big areas (phase 3).

**D5 — Tab in a composer.** Recommended: Tab leaves the composer (there is
no tab character in a message). The completion list still takes Tab first
while it is open.

**D6 — The palette's key.** Ctrl+Space is the input source switch on macOS
and on some Linux desktops. Recommended: Ctrl+Space and Ctrl+K everywhere,
Cmd+K on macOS. Not configurable in the first version.

**D7 — Commands are plain procs.** Recommended: a static table of
`Command` values, plus entries made when the palette opens. The headless
client's commands are not reused as text (`/view general`); where the two do
the same thing, the work moves into a proc both call.

**D8 — Matching.** Recommended: a subsequence match with bonuses for word
starts and for letters in a row, ties broken by recent use (the last 20
commands, kept in memory only for now).

## 1. Keys

In `key_callback`:

- Tab with Shift adds `.Back_Tab` instead of `.Tab`.
- Space on press adds `.Activate`. It still goes on to `char_callback`
  as text, so a text box with the focus types a space as before; whoever
  uses `.Activate` checks that no text box has the focus.
- Ctrl+Space and Ctrl+K (Cmd+K on macOS) add `.Palette` and stop there.

Enter is already microui's `.RETURN` in `ctx.key_pressed_bits`.

A small `key_take(ui, k) -> bool` that removes `k` from `ui.keys` and says
whether it was there replaces the `if .X in ui.keys { ui.keys -= {.X} … }`
pattern where the code is touched.

## 2. The focus ring

```odin
Nav_Item :: struct {
	id:   mu.Id,
	rect: mu.Rect,           // clipped to what is visible
	root: ^mu.Container,     // the root container it is drawn in
	text: bool,              // a text box: focusing it sets ctx.focus_id
}

UI_Nav :: struct {
	focus:    mu.Id,
	visible:  bool,
	items:    [dynamic]Nav_Item, // this frame's stops, in draw order
	activate: mu.Id,             // Enter or Space on this id this frame
}
```

`nav_control(ui, id, r, text := false) -> (activated: bool)`:

- appends the item (its root is the bottom of `ctx.container_stack`);
- if `visible && focus == id`, draws an outline around `r` in the accent
  color (`render.draw_rounded` with a border, CONTROL_RADIUS);
- returns `activate == id`.

The widgets treat `activated` as a press: `icon_button`, `stable_button`,
`list_row` and `tab_button` add `.SUBMIT`; `checkbox` flips; `dropdown`
opens its popup. `text_box`, `password_box` and `text_area` register with
`text = true` and don't use `activated`.

After `mu.end` in `draw_frame` ([ui_frame.odin](../../src/client/ui_frame.odin)),
before `ui.keys = {}`, `nav_after_frame`:

- If `.Tab` or `.Back_Tab` is still in `ui.keys`: find `focus` in `items`
  and step one forward or back, wrapping; with no focus, Tab takes the first
  item and Shift+Tab the last. Set `visible`, set `ctx.focus_id` for a text
  item (`focus_at` at the end of its text) and clear it otherwise. Ask for
  a frame (`ui_redraw`): the outline moves in the next one.
- Enter or `.Activate` with `visible` and a focus that isn't a text box: set
  `activate = focus` for the next frame. The press lands a frame late, the
  same way the completion list uses what the last frame worked out.
- A mouse press: `visible = false`, `focus = 0`.
- `focus` not among this frame's items (the page changed, a popup closed):
  clear it.

## 3. Popups, scrolling, and keys taken by others

As built:

- **Popups keep the focus.** While a popup is open (the context menus,
  through `begin_popup`, and the dropdown's list), Tab, Shift+Tab, Up and
  Down only move among the items whose `root` is that popup, and Escape
  closes it. Each says so in every frame it is drawn in (`nav_trap`). An
  item's root is the innermost root container, since popups are begun
  inside other windows.
- **Floating windows don't.** Search, forward, pins, the emoji picker and
  the like are not modal: their items come after the main window's in the
  Tab order, as they are drawn. F6 and Shift+F6 jump between areas (one per
  root container: the rail, the main window, each window over it), so a
  window opened with the mouse can be reached quickly. This was planned for
  phase 6 and came here instead.
- **Opened from the keyboard.** A root container that had no items in the
  last frame and appears within two frames of a keyboard press is the
  window or popup that press opened: its first item takes the focus (the
  dropdown's list starts at the current choice instead, `nav_focus_next`).
  When the focused item is gone again, the focus goes back to the opener
  (`UI_Nav.return_to`).
- **Into view.** Moving the focus to an item that sticks out of its
  container's body (the innermost one, a panel or the window) scrolls that
  container at once by the difference. microui puts the scroll back in range
  where the content doesn't scroll.
- **Keys taken by others.** The completion list already removes Tab; the
  same goes for anything else that wants Tab, Escape or Space first. Escape
  that nobody took hides the focus.
- **Text boxes and Space.** `.Activate` is ignored while `ctx.focus_id` is
  a text box (see 1).

## 4. The palette

```odin
Command :: struct {
	name:    string,                // "Mute microphone"
	detail:  string,                // dimmed: a key, a server's name
	enabled: proc(ui: ^UI) -> bool, // nil: always
	run:     proc(ui: ^UI, arg: rawptr),
	arg:     rawptr,
}

UI_Palette :: struct {
	open:     bool,
	placed:   bool,
	query:    Text_Field(128),
	matches:  [dynamic]Palette_Match, // index and score, best first
	selected: int,
	run:      Maybe(int),             // chosen; run after the frame
	recent:   [dynamic]string,        // command names, newest first
}
```

`palette_window` (new ui_palette.odin), modeled on `search_window`: centred
near the top, about 480 wide, at most 10 rows. Placed once on open, brought
to the front, `hover_root` set, `nav_trap` (3). The query box gets the focus
on open (`focus_at`). Keys before the box sees them, as in
`completion_keys`: Up and Down move `selected`, Enter chooses, Escape
closes. Each row is a `list_row` with the name and the dimmed detail;
clicking chooses. The chosen command runs after the frame, then the palette
closes.

First commands, each only while it makes sense:

| Command | Does |
| --- | --- |
| Mute / Unmute microphone | `set_muted(ui, !ui.muted)` |
| Deafen / Undeafen | the voice panel's deafen |
| Leave voice | the voice panel's leave |
| Share screen / Stop sharing | the voice panel's share |
| Camera on / off | the voice panel's camera |
| Search messages | `ui.search.open = true` |
| Settings | `ui.page = .Settings` |
| Buddies | `ui.page = .Buddies` (connected only) |
| Disconnect / Reconnect | the connect screen's actions |
| Toggle light / dark theme | theme.odin |

Mute and Deafen show their global hotkey as the detail
(`hotkeys.format(bound(ui, action))`).

Where a command calls what a button does, the button's code moves into a
proc both use, so they can't drift apart.

## 5. Dynamic entries and recent first

Made when the palette opens, from the View (locked while building):

- **Go to #channel** for each subscribed channel, with the server as the
  detail; running it opens the channel as a click in the channel list
  does.
- **Join voice in #room** for voice rooms the account may join.
- **Switch to server** for each server on the rail.
- **Message @name** for each buddy (opens the conversation).

Names are cloned into the palette's own arena, freed on close.

Matching and order as in D8. With an empty query, recent commands are
listed first, then the static ones.

## 6. The rest

- Move the 29 `mu.button` calls to `stable_button` (or a `button` wrapper
  with the label as id), so they become stops.
- Add `nav_control` to the custom controls that should be stops: user rows
  and the voice panel's own row (ui_users.odin, ui_voice_panel.odin), the
  roles grid (ui_roles.odin), the profile picker, the title bar's buttons.
  Chat messages are not stops; the message bar's buttons may become
  reachable through a "message actions" key later.
- Arrow keys inside lists: Tab enters a list (channels, users, settings
  categories) at its selected row; Up and Down move within it; Tab leaves
  it. A list registers as one stop with a "roving" child.
- Web: check that the browser doesn't take Ctrl+Space or Ctrl+K before the
  page sees it, and that Tab doesn't move the browser's own focus out of
  the canvas (prevent its default while the canvas has the focus).

## Testing

- `nav_after_frame`'s stepping on a hand-made item list: forward, back,
  wrapping, a trapped root, a focus that disappeared (ui_nav_test.odin).
- Matching scores and order (ui_palette_test.odin).
- By hand: settings and the connect screen with only the keyboard; Tab
  inside a dropdown and the search window; the composer with the
  completion list open; the palette on Windows, Linux, macOS and the web.
