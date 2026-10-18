# Screen share audio on the desktop

The goal: a native screen share includes sound without extra steps. When
the user starts sharing, the share menu also asks what audio goes with it:
**No audio**, or one of the **playback devices** (the default device
first). With a device picked, everything that plays on it is sent along
with the picture, except yap's own sounds. To share just one application,
the user picks No audio and then picks that application with the app
audio button, as they do today.

The browser already works this way. Its picker has its own "share audio"
checkbox (see the `web-share-audio` branch), so this is only about the
desktop.

Branch `screen-audio-share`, off `master`. Sizes as in `misc/next`.

| # | Change | Size | Status |
| --- | --- | --- | --- |
| 1 | tinyaac: list playback devices, capture one without our own process | L | done, untested on Windows/macOS |
| 2 | `audio.App_Share` for a device; one share at a time | S | done |
| 3 | Share menu: the audio choice, remembered in the settings | M | done |
| 4 | Screen share and audio start and stop together | S | done |
| 5 | System-picker platforms (Wayland portal, macOS 15) | S | done |

## Where things are today

- `ui_video.odin`: `share_button` / `share_menu` show the monitors and
  windows from `conn.video_sources`. Picking one calls
  `conn.video_share_source`. Where the system has its own picker
  (`conn.video_system_picker`), the button skips our menu and opens the
  system's picker directly.
- `ui_app_audio_native.odin` + `audio/app_audio_native.odin`: the app
  audio button captures **one application** through tinyaac
  (`audio/aac`, `deps/thirdparty/tinyaac/tinyaac.h`) into
  `Voice.app`. The network thread mixes that into every frame sent
  (`app_mix`), after the gate and noise suppression. The same ring
  carries the browser's share audio.
- tinyaac per platform:
  - Linux: a PipeWire capture stream connected to the app's output node.
  - Windows: WASAPI process loopback, `INCLUDE_TARGET_PROCESS_TREE`.
  - macOS: a Core Audio process tap with `processes = @[pid]`.
- Playback devices: miniaudio lists them for the Audio settings
  (`audio.Audio.outputs`). Its names and ids belong to miniaudio's
  backend (PulseAudio, WASAPI), not to tinyaac's.

## As built

- **tinyaac** (yap fork sections in `deps/thirdparty/tinyaac/tinyaac.h`):
  `tinyaac_device_list_create` returns an app-list of devices, with a new
  `is_default` field in `tinyaac_app_info`. `tinyaac_capture_create_device(list,
  index, exclude_pid, &capture)` works with the existing capture calls.
  Identifiers are `pipewire-sink:<id>`, `win-device:<endpoint id>` and
  `mac-device:<uid>`.
  - Linux: as planned. A non-autoconnected F32 stereo stream (FL/FR at
    48 kHz) and a registry listener that tracks clients (process id from
    their info, falling back to `pipewire.sec.pid`), playback streams,
    ports and links. It links every port of every stream that plays on
    the sink and isn't the excluded process's to our FL/FR, and unlinks
    them when they stop. If the sink goes away, it sends
    `TARGET_ENDED`. With no process to exclude, it captures the sink's
    monitor instead. The device list's default comes from the `default`
    metadata (`default.audio.sink`). `yap_aac.c` loads four more symbols:
    `pw_stream_get_node_id` and `pw_properties_set`/`_setf`/`_free`.
  - Windows: `IMMDeviceEnumerator` lists the active render endpoints
    by friendly name. With exclude_pid set, the capture uses process
    loopback in exclude mode. With 0, it uses plain endpoint loopback in
    the device's mix format. An invalidated device sends `TARGET_ENDED`.
  - macOS: the devices with output streams, by name and UID. The tap is
    `exclusive` (its process list is what's left out), with `deviceUID`
    and `stream = 0`, and the excluded process comes from
    `kAudioHardwarePropertyTranslatePIDToProcessObject`. The aggregate
    device stays as it is for apps, without subdevices, so that a device
    with its own microphone can't add it. Nothing reports the device
    going away.
- **D2** is decided in yap (`plays_on` in `ui_app_audio_native.odin`):
  on Windows it passes our PID only when the picked device is the
  settings' output device, or the default one when that is unset or
  gone. Linux and macOS always pass it.
- **Menu**: the choice is a list of rows (`list_row`), not a dropdown. A
  dropdown's list is a popup of its own, and clicking it would close the
  share menu before the pick arrives. Picking the default device saves
  `"default"`, so the share follows the system default. Any other device
  is saved by name.
- **Ending**: `app_audio_frame` stops a device share once the screen share
  is no longer Starting or Live. That covers the button, a closed window,
  a failure, and a cancelled system picker. Leaving voice stops both, as
  before. The "not in voice" case from item 4 can't happen, because the
  Share button is only in the voice panel.
- **Tested here (Linux, real PipeWire, a null sink)**: a C test with two
  tone players, excluding one by PID (native and PulseAudio clients),
  showed the excluded tone at 0 and the other at full level. A player
  that starts after the capture is linked, an excluded player that starts
  later stays out, and removing the sink ends the capture. ASan was
  clean. In the GUI (headless weston): the menu on both paths, the choice
  remembered, the share starting with the screen (yap's own playback on
  the same sink is not linked, the other player is), the app button
  green with "(with your screen)", stopping with the screen, being
  replaced by an app pick, and an app share outliving the screen share.
  Windows and macOS were only type-checked (Odin); their C hasn't been
  compiled.

## The catch: our own sound

If yap captures the device it plays voice on, everyone in the channel
hears themselves back, a moment late. So device capture must leave out
yap's own process. Each backend can do that:

- **macOS 14.2+**: `[[CATapDescription alloc] initExcludingProcesses:@[self]
  andDeviceUID:uid withStream:0]`. This is a tap on exactly that device,
  without yap. It's the cleanest of the three.
- **Windows 10 19041+**: process loopback in
  `PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE` mode, with our own
  PID. That gives everything except yap, but from **all** devices
  together, because process loopback isn't tied to a device. Plain
  endpoint loopback (`AUDCLNT_STREAMFLAGS_LOOPBACK` on the picked
  device) is tied to the device, but it includes yap. See D2.
- **Linux (PipeWire)**: a sink's monitor includes yap. Instead, create one
  capture node that doesn't autoconnect, and link every playback stream
  routed to the picked sink, except our own process's streams, to its
  input ports (`link-factory` through `pw_core_create_object`). A registry
  listener keeps this up to date: it links new streams, and unlinks
  streams that end or move to another sink. OBS's
  pipewire-audio-capture plugin does "everything except" the same way.
  This is the biggest part of item 1.

## 1. tinyaac: devices

New API, next to the app list. It stays in the "yap fork" style of the
header, with the additions marked.

	tinyaac_device_list_create / _count / _get / _destroy
	    -> { display_name, identifier, is_default }
	tinyaac_capture_create_device(list, index, exclude_pid, &capture)

The rest of the capture API (`set_callbacks`, `start`, `stop`, `destroy`,
the events) is the same as for applications, so `App_Share` doesn't
change. Identifiers: `pipewire-sink:<node id>`, `win-endpoint:<id>`,
`mac-device:<uid>`. Linux needs a few more `pw_` symbols in
`yap_aac.c`'s dlsym list (`pw_core_create_object`'s implementation is a
method call, but `pw_properties_set` and friends aren't).

Devices come from tinyaac rather than miniaudio, so the ids are the ones
the capture understands. The names agree with the Audio settings in
practice: pipewire-pulse and WASAPI both use the device description.

## 2. One share at a time

`audio.app_share_start_device(v, list, index)` next to
`app_share_start`. `UI_App_Audio` gains `kind: enum {App, Device}`. Only
one share feeds `Voice.app` at a time:

- Picking an application while a device is shared replaces the device
  share. The screen share goes on without sound.
- Starting a screen share with a device replaces an application share.

The app audio button shows a device share like an application share
(green, "Sharing the audio of Speakers (with your screen)"). Its menu
can stop it, and the volume slider applies to both.

## 3. The share menu

The audio choice goes at the top of `share_menu`, as a dropdown
(`ui_dropdown.odin`). Picking a monitor or a window below then starts
both.

	Audio: [ Speakers (default)  v ]
	Share a monitor:
	  ...

Setting: `"share_audio": ""` means no audio (D4), `"default"` means the
default device, and anything else is a device name. A name that isn't
listed anymore falls back to the default device. The menu remembers the last choice, so it takes no extra clicks
next time. It only appears where tinyaac came up
(`app_audio_available`). Elsewhere the menu looks as it does now.

## 4. Starting and stopping together

- When `video_share_source` is called with a device chosen, the device
  share starts in the voice that `sound_session` gives (the same as app
  audio). If we aren't in voice, there's nowhere to send the audio: the
  picture is shared alone, and the share button's hint says why.
- Stopping the screen share (button, or the shared window closing, or
  `.Failed`) stops a **device** share. It leaves an application share
  alone, because that was picked separately.
- Leaving voice stops the device share (`app_audio_session_gone`, as
  today), but not the screen share.

## 5. System-picker platforms

Where the system picks the source, the Share button opens the system's
picker directly today. With audio available, the button instead opens a
small menu: the same audio dropdown, then a "Choose screen or window..."
button that opens the system's picker. The alternative is to keep the
direct click and put the audio choice only in Settings > Screen sharing
(see D3).

## Not in scope (could follow)

- Picking a **window** to share could pick that window's application
  for audio (by `Video_Source.app` / PID), the way Discord does. The
  request was to keep that manual, so it isn't planned here.

## Decisions

All settled by the user on 2026-10-18.

- **D1** The menu offers No audio and every playback device.
- **D2** Windows lists the devices. The device yap plays voice on uses
  process loopback in exclude mode, so it gets everything but yap, from
  all devices. Any other device uses plain endpoint loopback, since yap
  isn't playing there.
- **D3** On system-picker platforms, a small menu comes first: the audio
  dropdown, then "Choose screen or window...".
- **D4** The first-time default is **No audio**. After that, the last
  choice is remembered.
- **D5** Build all five items now. Linux is tested here. Windows and
  macOS need the user's test.
