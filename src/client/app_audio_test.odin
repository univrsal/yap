#+build !wasi
package client

import "core:os"
import "core:testing"

import "common:."

// Muting mutes a shared application too unless it's switched off: on by
// default, also for settings from before there was such a setting.
@(test)
test_app_mute_setting :: proc(t: ^testing.T) {
	path := "yap-app-mute-test.json"
	defer os.remove(path)

	testing.expect(t, common.store_write(path, `{"name": "me"}`))
	old := settings_load(path)
	testing.expect(t, old.mute_app_audio_with_mic)
	testing.expect(t, app_audio_command(&old).mute_with_mic)
	settings_destroy(&old)

	s := DEFAULT_SETTINGS
	s.mute_app_audio_with_mic = false
	s.app_audio_volume = 0.5
	settings_save(path, s)
	loaded := settings_load(path)
	defer settings_destroy(&loaded)
	testing.expect_value(t, app_audio_command(&loaded), App_Audio_Command{volume = 0.5})
}
