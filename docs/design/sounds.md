# Sounds: a choice for every event

The goal: for every event that makes a sound, the user picks what it
plays from a dropdown: any sound of the built-in packs, no sound, or a
sound file of their own. Some events are new, because the Skype pack
has sounds nothing plays yet: a call declined (`busy`), the connection
going bad in a call or voice channel (`reconnect`), and staying bad
(`reconnect_loop`).

Branch `sound-settings`, off `notifications`. Sizes as in `docs/design/next.md`.

| # | Change | Size | Status |
| --- | --- | --- | --- |
| 1 | Packs as folders; each event's sound looked up by name | S | done |
| 2 | The setting, and a Sounds page with a dropdown per event | M | done (2936269) |
| 3 | A sound file of one's own (desktop) | M | done (2936269) |
| 4 | New events: call declined, call ended, file offered, connection trouble; Mail split in two | M | done (2936269) |
| 5 | Packs as presets: "use this pack" | S | done (2936269) |
| 6 | Web: one's own sound file in the browser | M | done (e1c2e6d) |

## Where things are today

- `src/client/assets/soundpacks/<pack>/<name>.opus`: `base` (ring,
  ringback, muted, unmuted), `aim` (join, leave, msg, mail, done,
  welcome, goodbye), `skype` (msg, done, ring, ringback, login, logout,
  hangup, busy, incoming_file, reconnect, reconnect_loop, and `old_`
  versions of msg, ring, ringback, hangup), `icq` (message, notify,
  bell, file, file_done, online, ring, old_ring, knock, startup; from the
  original WAVs, turned down to about the AIM pack's loudness, knock
  padded to 1.2 s so its loop pauses). All 48 kHz mono Opus.
- `audio.Notification_Kind`: Join, Leave, Message, Welcome, Goodbye,
  Muted, Unmuted, Mail, Done. `audio.Loop_Kind`: Ring, Ringback.
- Where they are played: `conn/channels.odin` (join/leave of our voice
  room), `conn/messages.odin` (Message; Mail for mentions and DMs),
  `conn/convs.odin` (Mail once for DMs unread at login),
  `conn/files.odin` and `conn/attachments.odin` (Done),
  `conn/calls.odin` (the ring loops), `ui_app_sounds.odin`
  (Welcome/Goodbye, desktop only), `audio/notification.odin`
  (Muted/Unmuted feedback).
- Each connection's `Voice` decodes its own copy of every sound
  (`notifications_init`), and mixes them into its playback.
- One setting: `notification_volume` (Audio page).

## 1. Packs as folders

*Done.* `audio/sound_packs.odin`: `SOUND_PACKS` takes each pack's folder
with `#load_directory`, so a file dropped into a pack is in it at the
next build, with no code. A sound is named `pack/file` ("aim/msg").
`DEFAULT_SOUNDS` and `DEFAULT_LOOPS` give each event its sound, the same
ones as before the move. `Notification_Sounds` holds the decoded clips
in arrays by event (`clips`, `loops`) instead of a field each. A test
decodes every file of every pack and checks that every default exists.

## 2. The setting and the Sounds page

Setting (settings.json), only the events the user changed:

	"sounds": {"message": "skype/msg", "mention": "none", "ring": "custom:ring.ogg"}

A value is a built-in sound's name, `none`, or `custom:<file>` (3).
Missing or unknown means the default, so a pack's renamed file falls
back rather than going silent. Event names in the file are the enum's
names in lower case, so they survive reordering.

Applying: a `Sounds_Command` to every connection (as
`Notification_Volume_Command` is), carrying the event and the choice.
The voice thread decodes the new clip and swaps it in; a clip being
replaced is first dropped from `playing`/`loop`, since the mixer
holds slices into it.

While at it, decode each sound once for the whole client (a cache keyed
by name, shared by every connection's `Voice`) instead of once per
connection: with all packs selectable and several servers, the copies
add up (a second of 48 kHz stereo f32 is 384 KB).

UI: a new client category **Sounds** (D1), one row per event:

	Message            [ AIM: msg            v ]  [>]
	Mention            [ AIM: mail           v ]  [>]
	Incoming call      [ Yap: ring           v ]  [>]
	...
	Volume             [------o------] 100%

- The dropdown is a new widget (`dropdown` in ui_widgets): a button
  showing the choice, opening a popup (as the rail's menu does) with
  "No sound", then the sounds grouped by pack, then "Choose a file…".
  microui has no dropdown, so this is the bulk of the work; it is kept
  generic for later use (theme, quality).
- `[>]` plays the choice once, through the UI's own Voice
  (`ui_app_sounds.odin`), so it works without a server too. On the web
  it needs no special case, the click being the user gesture.
- The volume slider moves here from Audio.

*As built:* `audio.Sound_Event` replaces Notification_Kind and Loop_Kind
(one enum, loops marked in `SOUND_EVENTS`). `audio/sound_store.odin` is
the shared, refcounted store; `notifications_set` swaps an event's sound
and first stops it if it is playing. `settings.sounds` holds only what
differs from the default. The dropdown is `ui_dropdown.odin` (a popup
drawn at the end of the frame, scrolled to the current choice; closed
when its page isn't drawn). The page is `ui_sounds.odin`: grouped under
Messages, Voice, Calls and The client, a play button beside each row
(it plays through the UI's own Voice, `app_sound_preview`, which also
works on the web), and picking a sound plays it. The volume slider moved
here and saves like the other sliders (`settings_dirty`).

## 3. One's own sound file (desktop)

"Choose a file…" opens the native dialog (`client:dialogs`, as for
attachments), filtered to sound files.

- Formats: Opus (our own decoder), WAV, FLAC and MP3 (miniaudio's
  decoders: drop `MA_NO_DECODING` in `yap_audio.c`, decode to 48 kHz
  stereo f32, which also resamples). Not Vorbis or AAC (D6).
- Limits: the file at most 5 MB; a sound is cut at 10 s, a loop (ring,
  ringback, connection trouble) at 30 s.
- The file is copied into the config folder (`<config>/sounds/`), and
  the setting names the copy (D7), so moving or deleting the original
  doesn't break it. Choosing another sound deletes the copy if nothing
  else uses it.
- A file that won't decode: a message under the row, the default plays.

*As built:* D6 measured: miniaudio's WAV, FLAC and MP3 decoders add
138 KB to libyap_audio (93 KB to 231 KB of code), under the 300 KiB
limit, so all four formats are in; the web build leaves them out
(`MA_NO_DECODING` under Emscripten). Every sound is cut at 30 s when
decoded, and a sound that isn't a loop plays at most 10 s of that. The
copy keeps the file's name (made safe, at most 64 bytes); another file
of the same name becomes "name-2.ext", the same file again is the same
copy. A copy no event plays any more is deleted. A file that is gone or
broken at start gets a note under its row. `ui_sounds_native.odin`;
tested in `ui_sounds_test.odin`.

## 4. New events

| Event | Plays when | Default (D5) |
| --- | --- | --- |
| Call declined | our outgoing call ends unanswered: `.Declined`, `.Unanswered` (rang `CALL_RING_SECONDS`, 30 s), or refused at once because the callee is unreachable (`.Closed`); not when we cancel it ourselves | none |
| Call ended | an active call we are in ends (new event?) | none |
| File offered | a DM file offer comes in (`conn/files.odin`, `.Incoming`) | none |
| Connection trouble | the connection goes bad while in a voice room or a call | none |
| Connection still bad | it stays bad: loops until it recovers or is lost | none |

Generally the default for all sounds should be none, except for:
- Incoming call (base/ring)
- Outgoing call (base/ringback)
- Muted/Unmuted, Deafened/Undeafened (muted/unmuted for both muted/deafened)

All other sound events can be none by default. This should be the default sound pack.

And Mail split in two (D3): **Direct message** (a DM, and the DMs unread
at login) and **Mention**, both silent by default like the rest.
**Deafened** and **Undeafened** become events of their own, apart from
Muted and Unmuted, playing base/muted and base/unmuted by default.
(Confirmed 2026-10-15; this also means join, leave, message, done,
welcome and goodbye go silent for everybody who hasn't picked them.)

Connection trouble (D4): bad means `lost_run >= LOST_IN_A_ROW` in
`conn/ping.odin` (three seconds without an answered ping), only while
our voice is in a room or we are in a call. Then `reconnect` plays once,
and if it is still bad when that has played, `reconnect_loop` repeats
(as a `Loop_Kind`, under the ring, which wins if both). It stops when a
pong comes back, or when the connection is given up as lost
(`CONNECTION_LOST`, 30 s), which then plays Leave. High latency alone
(Poor by RTT) doesn't count: the call still works, just late.

### A call while already in voice (D10, D11)

How it is today:

- **In a call, same server:** a second call never rings. `call_start`
  (server/calls.odin) answers the caller `.Conflict` when either
  account has a call, ringing or active; the caller sees "X is already
  in a call", the callee learns nothing at all, not even a missed call.
  The same goes while somebody else's call is still ringing for them.
- **In a voice channel, same server:** the call rings as usual, the
  full ring mixed over the channel. Accepting moves the connection out
  of the channel into the call's room (`call_accept`); when the call
  ends it is in no room, not back in the channel.
- **In a call or channel on another server:** each server knows only
  itself, so it rings, at full volume over the call, with Accept and
  Decline in the voice panel (`ui_voice_panel.odin`, "other"). Accepting
  leaves the voice elsewhere first (`leave_voice_elsewhere`), hanging up
  the call there.

New event **Call while in voice**: a loop (skype/knocking, 3 s, the
length of the ringtones), played instead of the ring when our voice is
in a channel or a call, on this server or another. Default: knocking,
since a full ring over a conversation is the harsher choice, or the
ring if the Default pack should stay as it is (D11). A session knows
only its own room, so the UI tells each session whether the voice is
busy elsewhere (a command like `Notification_Volume_Command`), and
`call_sounds` picks `.Knock` over `.Ring`.

For the same server (D10):

- **a. Keep refusing, but tell the callee.** The server leaves a missed
  call in the DM as it does for an offline callee (`call_note`), and
  the callee's client plays Call while in voice once. Server: a few
  lines; no protocol change. The caller hears Call declined.
- **b. Call waiting.** A second call may ring while one is active;
  Accept hangs up the first and takes the second. `call_of` and the
  client's `Call_Client` hold one call per account, so this means a
  call list on both sides, a protocol bump, and a panel showing two
  calls. L, its own item.

*As built:* as planned. Call not answered also plays when the server
refuses the call at once (`.Closed`: unreachable; `.Conflict`: already
in a call). The knock for a refused call (D10 a) is the client seeing the
missed-call note in the DM arrive, from someone other than the peer,
while it is in a call: no protocol change. Knock vs ring is decided in
`conn/sounds.odin` (`loop_sounds`), with the UI telling each session
whether the voice is busy on another server (`Voice_Elsewhere_Command`,
`sounds_frame`). Connection trouble is checked with every ping
(`trouble_step`); when the connection is given up, the loop stops, and
leaving voice plays Leave as before (if one is chosen). Not tried with a
real call or a real bad connection yet; `test_call_sounds` covers the
call outcomes and the knock.

## 5. Packs as presets

On the Sounds page, above the rows: `Sound pack [ AIM v ] [Use]`.
Using a pack sets every event the pack has a sound for to that sound,
leaving the others as they are. Which file of a pack fits which event
is a table in `sound_packs.odin` (Skype's `login` is Welcome, `logout`
Goodbye, `incoming_file` File offered, and so on).

There should also be a Default pack as described in 4. New Events and a Quiet 
pack that sets all to none.


*As built:* a row of buttons, "Use the sounds of: Default, Quiet, AIM,
Skype, ICQ", rather than a dropdown and a Use button. Default forgets
every choice, Quiet sets every event to no sound, and the packs set the
events they have sounds for (`audio.SOUND_PRESETS`).
## 6. Web

The browser decodes any format it knows (`decodeAudioData`, in a new
`web/sounds.js` like `decode.js`), resampled to 48 kHz. The file is kept
in IndexedDB (as the image cache is), keyed by the name in the setting.
Welcome and Goodbye stay off on the web (no sound before the first
click, nothing to wait for on quitting); their rows are hidden there.

*As built:* `web/sounds.js` and `ui_sounds_web.odin`. The page picks the
stored name (as on the desktop, "-2" for another file of the same name,
the same name for the same bytes) and hands the decoded samples to the
client; at start the stored files are decoded again and the sessions
told once they are in. Tested in headless Chromium: an MP3 picked,
kept, loaded again after a reload, and deleted from IndexedDB when no
event played it any more.

## Decisions

| # | Question | Recommendation |
| --- | --- | --- |
| D1 | Where the settings go | A new client category "Sounds", after Audio; the volume moves there |
| D2 | What each dropdown lists | Every sound of every pack, grouped by pack, for every event; not only the ones meant for it |
| D3 | Split Mail into Direct message and Mention | Yes |
| D4 | What counts as the connection going bad | Three seconds without answered pings, in voice or a call; not latency |
| D5 | Defaults for the new events | All set to none as described in 4. |
| D6 | Formats of one's own files | Opus, WAV, FLAC, MP3 on the desktop - We should test first how much this increases the binary size, if it's too much (more than 300KiB, we only support opus and wav); whatever the browser decodes on the web |
| D7 | Keep one's own file where it is, or copy it | Copy into the config folder |
| D8 | A volume per event | No, one volume for all; later if wanted |
| D9 | Does a missed outgoing call (no answer) play Call declined too | Yes, it is the same "nobody picked up". The server ends a ringing call after `CALL_RING_SECONDS` (30 s) as `.Unanswered`; a callee with no connection and no push is refused at once. Cancelling our own call plays nothing |
| D10 | A call to somebody already in a call on the same server | a: still refused, but the callee gets a missed call and a knock; call waiting (b) later if wanted |
| D11 | Default for Call while in voice | skype/knocking in the Default pack |

## Memory (2026-10-16)

The sounds took more memory than wanted (Skype preset: 20.5 MB decoded,
against 8.2 MB on `extended`). Three changes, on branch `sound-memory`:

- A sound is decoded into a buffer of its exact size (from the Ogg
  stream's last granule position), not a growing one: that had wasted
  40-70%.
- A sound whose two channels are the same is kept as mono and mixed to
  both speakers (`Playing.channels`). All the built-in sounds are mono or
  the same on both sides.
- Server connections don't hold the start-up and quit sounds
  (`audio.APP_SOUNDS`), which only the UI plays.

Measured (headless weston, connected to a local server, Settings >
Memory > Write to log): decoded sounds 2.2 MB with the defaults (was
7.0), 3.1 MB with AIM (10.2), 6.1 MB with Skype (20.5); `extended`'s 11
sounds took 8.2 MB. RSS while connected: 208 MB with the defaults, 213
MB with Skype; `extended` 212 MB.
