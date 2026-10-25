package video

import "common:proto"

// The video backend: capture, encoding and decoding, and the pictures to
// draw. It is the yap_video library on a desktop (native.odin) and the
// browser's own codecs on the web (web.odin), and the rest of the client does
// not tell them apart. conn decides what to send and watch, and this does it.

// STREAMS is how many streams a user can have: the screen (0), then the cameras.
STREAMS :: 1 + proto.MAX_CAMERAS

// Key names one of a user's streams.
Key :: struct {
	user:   proto.User_Num,
	stream: proto.Video_Stream,
}

// How a share is set up (see share_source).
Share_Config :: struct {
	max:     [2]i32,
	fps:     int,
	kbit:    int,
	encoder: string, // "" picks the best encoder that works
	cursor:  bool,
}

// Camera_Device is a camera that can be picked in the settings: its id, as
// settings.camera_device stores it, and its name.
Camera_Device :: struct {
	id:   string,
	name: string,
}

// What a capture is doing.
Share_State :: enum i32 {
	Off,
	Starting,
	Live,
	Failed,
}

Source_Kind :: enum {
	Monitor,
	Window,
}

Source :: struct {
	kind:          Source_Kind,
	id:            u64,
	name:          string,
	app:           string, // a window's program or a monitor's device
	width, height: int,
	primary:       bool,
}

Encoder :: struct {
	name:  string, // what settings.share_encoder stores
	label: string,
	works: bool,
}
