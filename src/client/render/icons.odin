package render

import "core:math"
import mu "vendor:microui"

// The UI's icons, which avoid the need to ship an icon font. Each icon is a
// handful of shapes (discs, capsules, rounded boxes, arcs) written as
// distance functions over a unit square and rasterized into an alpha atlas,
// the same way font.odin rasterizes glyphs. Coverage is computed from the
// distance, so the edges are smooth, and the atlas is rebuilt at the display's
// density whenever the scale changes, so icons stay sharp on high-DPI screens.
//
// The atlas has a single alpha channel like the font's, so the shader paints
// an icon in whatever color it is drawn with. This means icons take the color
// of the text they stand next to.
//
// Icons reach the renderer as microui icon commands whose ids are offset by
// UI_ICON_BASE. render.odin decodes them again.

Icon :: enum {
	Mic, // a microphone: the user can be heard
	Mic_Off, // muted: a microphone with a line through it
	Sound, // a speaker with sound coming out: the user hears the others
	Sound_Off, // deafened: a speaker with a line through it
	Settings, // sliders
	Send, // a paper dart: send the message in the chat box
	Screen, // a monitor: sharing a screen, or watching one
	Buddies, // two people: the buddy list
	Remove_Buddy, // a person with a line through them: remove from buddies
	File, // a sheet of paper with a corner turned down: send a file
	Trash, // a bin with its lid on: delete
	App_Audio, // two notes: share an application's audio
	Pin, // a drawing pin: pinned messages
	Smiley, // a smiling face: the emoji picker
	Log, // a framed page of lines: the log
	Search, // a magnifying glass: searching messages
	Attach, // a paperclip: attach files to a message
	Download, // an arrow pointing down into a tray: save a file
	// Kinds of file, shown next to the file names in a message (File is used
	// for all other kinds and App_Audio's notes for sound).
	Archive, // a sheet with a zip down it
	Picture, // a frame with a hill and the sun
	Video, // a frame with a play button
	Text_File, // a sheet with lines of text
	Eye, // an eye: show a message as it will look (the composer's preview)
	Reply, // an arrow that goes down and curves to the right: reply in a thread
	Edit, // a pencil: edit a message
	Phone, // a telephone receiver: call someone
	Hang_Up, // a receiver lying flat with its ends pointing down: decline a call
	Mail, // a closed envelope: for direct messages
	Screen_Off, // a monitor with a line through it: stop watching a screen
	Fullscreen, // four corners pointing out: fill the screen
	Exit_Fullscreen, // four corners pointing in: back from fullscreen
	Pop_Out, // an arrow out of a frame's corner: move into its own window
	Pop_In, // an arrow into a frame's corner: move back from its own window
	Camera, // a video camera: turn our camera on, or somebody's is on
	Camera_Off, // a video camera with a line through it
	// The window's own controls, for where Windows does not provide them
	// (ui_titlebar_windows.odin).
	Minimize, // a line
	Maximize, // a box
	Restore, // two boxes, one behind the other
	Close, // a cross
	// Replacements for microui's own icons, which are bitmaps made for a
	// single density (render.odin).
	Check, // a tick: a checked checkbox
	Collapsed, // a triangle pointing right: a collapsed tree node
	Expanded, // a triangle pointing down: an expanded tree node
}

// Icon command ids start here, above microui's own icons and below the ids of
// pictures (IMAGE_ICON_BASE, render.odin).
UI_ICON_BASE :: 100

// The icon size in logical pixels. Icons are square and drawn at this size
// everywhere, so a single atlas at one size works for all of them.
ICON_SIZE :: 16

// The id to use for drawing this icon (mu.draw_icon, icon_button).
icon_id :: proc(icon: Icon) -> mu.Icon {
	return mu.Icon(UI_ICON_BASE + int(icon))
}

Icon_Atlas :: struct {
	scale:  f32, // physical pixels per logical pixel the atlas was built for
	side:   i32, // one icon's side, in physical pixels
	width:  i32,
	height: i32,
	pixels: []u8, // width * height, one alpha byte per texel
}

// icon_atlas_build rasterizes every icon side by side at `scale`. If that
// fails, it returns false and leaves the atlas unchanged, so the caller can
// keep drawing with the existing atlas.
icon_atlas_build :: proc(a: ^Icon_Atlas, scale: f32) -> bool {
	side := i32(math.round(ICON_SIZE * scale))
	if side <= 0 {
		return false
	}
	width, height := side * i32(len(Icon)), side
	pixels := make([]u8, int(width) * int(height))

	for icon in Icon {
		left := int(icon) * int(side)
		for y in 0 ..< int(side) {
			for x in 0 ..< int(side) {
				d := texel_distance(icon, x, y, int(side))
				// The coverage fades over one texel across the edge.
				alpha := clamp(0.5 - d, 0, 1)
				pixels[y * int(width) + left + x] = u8(math.round(alpha * 255))
			}
		}
	}

	delete(a.pixels)
	a.scale, a.side, a.width, a.height, a.pixels = scale, side, width, height, pixels
	return true
}

// icon_rgba draws one icon on its own, in color, for cases that need a
// picture instead of a piece of the atlas, such as the tray icon
// (ui_tray.odin). `side` is the picture's size in pixels, and the caller owns
// the result.
icon_rgba :: proc(icon: Icon, side: int, color: mu.Color, allocator := context.allocator) -> []u8 {
	pixels := make([]u8, side * side * 4, allocator)
	for y in 0 ..< side {
		for x in 0 ..< side {
			d := texel_distance(icon, x, y, side)
			// The shape determines the picture's transparency, and the color is
			// flat.
			alpha := clamp(0.5 - d, 0, 1) * f32(color.a) / 255
			i := (y * side + x) * 4
			pixels[i], pixels[i + 1], pixels[i + 2] = color.r, color.g, color.b
			pixels[i + 3] = u8(math.round(alpha * 255))
		}
	}
	return pixels
}

icon_atlas_destroy :: proc(a: ^Icon_Atlas) {
	delete(a.pixels)
	a^ = {}
}

// The shapes. Every icon lives in the unit square with y pointing down, and
// each proc returns the signed distance to its outline, in the same units
// (negative inside, positive outside). Shapes are combined by taking the
// nearer of two (a union) or by cutting one out of the other.

@(private = "file")
Point :: [2]f32

// Where the line through a muted icon runs, how wide it is, and how large a
// gap it leaves around itself. The gap is cut out of the icon first, so the
// line reads as a separate line instead of more of the same shape.
@(private = "file")
SLASH_FROM :: Point{0.15, 0.13}
@(private = "file")
SLASH_TO :: Point{0.85, 0.87}
@(private = "file")
SLASH_WIDTH :: 0.09
@(private = "file")
SLASH_GAP :: 0.045

// texel_distance returns the distance in texels from the center of texel
// `x, y` of an icon that is `side` texels square to the icon's outline.
@(private = "file")
texel_distance :: proc(icon: Icon, x, y, side: int) -> f32 {
	centre := Point{f32(x) + 0.5, f32(y) + 0.5}
	if d, ok := window_control(icon, centre, f32(side)); ok {
		return d
	}
	// The coordinates in the unit square that the shapes are written in.
	return icon_distance(icon, centre / f32(side)) * f32(side)
}

@(private = "file")
icon_distance :: proc(icon: Icon, p: Point) -> f32 {
	switch icon {
	case .Mic:
		return microphone(p)
	case .Mic_Off:
		return crossed_out(microphone(p), p)
	case .Sound:
		return nearer(speaker(p), speaker_sound(p))
	case .Sound_Off:
		return crossed_out(speaker(p), p)
	case .Settings:
		return sliders(p)
	case .Send:
		return dart(p)
	case .Screen:
		return monitor(p)
	case .Buddies:
		return two_people(p)
	case .Remove_Buddy:
		return crossed_out(one_person(p), p)
	case .File:
		return document(p)
	case .Trash:
		return bin(p)
	case .App_Audio:
		return notes(p)
	case .Pin:
		return drawing_pin(p)
	case .Smiley:
		return smiley(p)
	case .Log:
		return log_page(p)
	case .Search:
		return magnifier(p)
	case .Attach:
		return paperclip(p)
	case .Download:
		return download(p)
	case .Archive:
		return archive(p)
	case .Picture:
		return picture(p)
	case .Video:
		return video(p)
	case .Text_File:
		return text_file(p)
	case .Eye:
		return eye(p)
	case .Reply:
		return hooked_arrow(p)
	case .Edit:
		return pencil(p)
	case .Phone:
		return receiver(p)
	case .Hang_Up:
		return hung_up(p)
	case .Mail:
		return mail_letter(p)
	case .Screen_Off:
		return crossed_out(monitor(p), p)
	case .Fullscreen:
		return corners(p, false)
	case .Exit_Fullscreen:
		return corners(p, true)
	case .Pop_Out:
		return popping(p, false)
	case .Pop_In:
		return popping(p, true)
	case .Camera:
		return video_camera(p)
	case .Camera_Off:
		return crossed_out(video_camera(p), p)
	case .Minimize, .Maximize, .Restore, .Close:
		// These are drawn in texels instead (window_control).
		return 1
	case .Check:
		d := capsule(p, {0.24, 0.52}, {0.42, 0.70}, CHECK_STROKE)
		return nearer(d, capsule(p, {0.42, 0.70}, {0.76, 0.30}, CHECK_STROKE))
	case .Collapsed:
		return triangle(p, {0.28, 0.18}, {0.72, 0.5}, {0.28, 0.82})
	case .Expanded:
		return triangle(p, {0.18, 0.28}, {0.82, 0.28}, {0.5, 0.72})
	}
	return 1
}

@(private = "file")
CHECK_STROKE :: 0.12

// window_control returns the distance from `p` (in texels, in an icon that
// is `side` texels square) to the outline of one of the window's own
// controls, and `ok` tells whether the icon is one of those. These icons are
// thin lines (one pixel at the icon's usual size and more only from about
// 1.75x up), and a line that thin is only sharp where it covers whole texels.
// A line written in the unit square like the other icons would fall across
// two half-covered rows at some sizes and on a single row at others, which
// makes it look thicker and grayer at some sizes than at others. So these
// icons are computed in texels, with lines made of whole texels and their
// edges always on texel edges.
@(private = "file")
window_control :: proc(icon: Icon, p: Point, side: f32) -> (d: f32, ok: bool) {
	width := max(1, math.floor(side / ICON_SIZE + 0.25))
	// Where the middle of a line goes for it to be at `v` across the
	// square: on a texel's center for an odd width, on a texel edge for an
	// even width.
	at :: proc(v, side, width: f32) -> f32 {
		c := v * side
		return math.round(c) if int(width) % 2 == 0 else math.floor(c) + 0.5
	}
	// A box outline that is `width` thick, with the middles of its lines
	// running from `lo` to `hi`. Its corners are square, so its edges stay
	// on texel edges.
	outline :: proc(p, lo, hi: Point, width: f32) -> f32 {
		centre, half := (lo + hi) / 2, (hi - lo) / 2
		outer := rounded_box(p, centre, half + width / 2, 0)
		inner := rounded_box(p, centre, half - width / 2, 0)
		return max(outer, -inner)
	}
	lo, hi := at(0.2, side, width), at(0.8, side, width)
	switch icon {
	case .Minimize:
		y := at(0.5, side, width)
		return rounded_box(p, {(lo + hi) / 2, y}, {(hi - lo + width) / 2, width / 2}, 0), true
	case .Maximize:
		return outline(p, {lo, lo}, {hi, hi}, width), true
	case .Restore:
		// The box in front hides the part of the box behind it that it
		// covers, plus a gap of one line width around it.
		near, far := at(0.34, side, width), at(0.66, side, width)
		front := outline(p, {lo, near}, {far, hi}, width)
		back := outline(p, {near, lo}, {hi, far}, width)
		covered := rounded_box(
			p,
			{(lo + far) / 2, (near + hi) / 2},
			{(far - lo) / 2 + width * 1.5, (hi - near) / 2 + width * 1.5},
			0,
		)
		return nearer(front, max(back, -covered)), true
	case .Close:
		return nearer(
				capsule(p, {lo, lo}, {hi, hi}, width),
				capsule(p, {hi, lo}, {lo, hi}, width),
			),
			true
	case .Mic,
	     .Mic_Off,
	     .Sound,
	     .Sound_Off,
	     .Settings,
	     .Send,
	     .Screen,
	     .Buddies,
	     .Remove_Buddy,
	     .File,
	     .Trash,
	     .App_Audio,
	     .Pin,
	     .Smiley,
	     .Log,
	     .Search,
	     .Attach,
	     .Download,
	     .Archive,
	     .Picture,
	     .Video,
	     .Text_File,
	     .Eye,
	     .Reply,
	     .Edit,
	     .Phone,
	     .Hang_Up,
	     .Mail,
	     .Screen_Off,
	     .Fullscreen,
	     .Exit_Fullscreen,
	     .Pop_Out,
	     .Pop_In,
	     .Camera,
	     .Camera_Off,
	     .Check,
	     .Collapsed,
	     .Expanded:
	}
	return 0, false
}

// A telephone receiver with the earpiece at the top right and the mouthpiece
// at the bottom left. It consists of a thick quarter of a ring that bulges to
// the bottom right and, at each end, a pad turned in towards the middle. The
// pads are blended into the handle so the three read as one piece.
@(private = "file")
receiver :: proc(p: Point) -> f32 {
	// Drawn bulging to the bottom left and then mirrored.
	q := Point{1 - p.x, p.y}
	CENTRE :: Point{0.70, 0.30}
	RADIUS :: 0.48
	BLEND :: 0.07
	handle := arc(q, CENTRE, RADIUS, 0.11, .Bottom, CENTRE.y)
	handle = max(handle, q.x - CENTRE.x)
	// The pads sit on the ends. They reach a little past the ends along the
	// handle and in towards the middle.
	ear := rounded_box(q, {CENTRE.x - RADIUS + 0.04, CENTRE.y - 0.04}, {0.12, 0.09}, 0.07)
	mouth := rounded_box(q, {CENTRE.x + 0.04, CENTRE.y + RADIUS - 0.04}, {0.09, 0.12}, 0.07)
	d := blend(handle, ear, BLEND)
	return blend(d, mouth, BLEND)
}

// The receiver put down: it is turned so that its back bulges up and the
// earpiece and mouthpiece hang down at either end, as on a hang up button.
@(private = "file")
hung_up :: proc(p: Point) -> f32 {
	// Each point is looked up at the position it came from before the
	// receiver was turned, which is 135 degrees back. This moves the bulge
	// from the bottom right to the top. Lying flat, the receiver is wider
	// than before, so it is drawn a little smaller. It is also shallower, so
	// it is drawn a little lower to stay in the middle.
	C :: math.SQRT_TWO / 2
	SIZE :: 0.9
	CENTRE :: Point{0.5, 0.5}
	d := (p - CENTRE - {0, 0.06}) / SIZE
	return receiver(CENTRE + {-C * d.x - C * d.y, C * d.x - C * d.y}) * SIZE
}

// blend joins two shapes like nearer, but rounds off the corners where they
// meet so that they run into each other.
@(private = "file")
blend :: proc(a, b, k: f32) -> f32 {
	h := clamp(0.5 + 0.5 * (b - a) / k, 0, 1)
	return math.lerp(b, a, h) - k * h * (1 - h)
}

// A closed envelope. It has an outline the size of the monitor's, a flap
// folded down from the top as a solid triangle, and two folds that run from
// under the flap's point to the bottom corners.
@(private = "file")
mail_letter :: proc(p: Point) -> f32 {
	STROKE :: 0.085
	CENTRE :: Point{0.5, 0.5}
	HALF :: Point{0.39, 0.29}
	ROUND :: 0.06
	L, R :: CENTRE.x - HALF.x, CENTRE.x + HALF.x
	T, B :: CENTRE.y - HALF.y, CENTRE.y + HALF.y
	inside := rounded_box(p, CENTRE, HALF, ROUND)
	d := abs(inside) - STROKE / 2
	// The flap, which is kept inside the outline at its rounded corners.
	flap := max(triangle(p, {L, T}, {R, T}, {CENTRE.x, 0.58}), inside)
	d = nearer(d, flap)
	// The folds, from just inside the bottom corners to under the flap.
	FOLD :: STROKE * 0.75
	IN :: ROUND / 2
	d = nearer(d, capsule(p, {L + IN, B - IN}, {CENTRE.x, 0.44}, FOLD))
	return nearer(d, capsule(p, {R - IN, B - IN}, {CENTRE.x, 0.44}, FOLD))
}

// Four corners, one in each quarter of the square. They point out to its
// edges for entering fullscreen or fold in towards the middle for leaving it.
// This draws the top left corner, and the others are its mirror images.
@(private = "file")
corners :: proc(p: Point, inwards: bool) -> f32 {
	STROKE :: 0.1
	NEAR :: 0.18 // distance from the square's edge where an outward corner sits
	FAR :: 0.40 // how far its arms reach
	q := Point{0.5 - abs(p.x - 0.5), 0.5 - abs(p.y - 0.5)}
	if inwards {
		// The corner at the middle end, with its arms reaching out to the
		// edges.
		d := capsule(q, {FAR, FAR}, {FAR, NEAR}, STROKE)
		return nearer(d, capsule(q, {FAR, FAR}, {NEAR, FAR}, STROKE))
	}
	d := capsule(q, {NEAR, NEAR}, {NEAR, FAR}, STROKE)
	return nearer(d, capsule(q, {NEAR, NEAR}, {FAR, NEAR}, STROKE))
}

// Popping a picture out of the window or back in. It is a frame that is open
// at its top right corner, with an arrow across the gap between the frame's
// middle and that corner. The arrow points out to the corner or in from it.
@(private = "file")
popping :: proc(p: Point, inwards: bool) -> f32 {
	STROKE :: 0.085
	d := abs(rounded_box(p, {0.44, 0.56}, {0.32, 0.32}, 0.07)) - STROKE / 2
	d = cut(d, rounded_box(p, {0.80, 0.20}, {0.26, 0.26}, 0))
	d = nearer(d, capsule(p, {0.40, 0.60}, {0.84, 0.16}, STROKE))
	if inwards {
		d = nearer(d, capsule(p, {0.40, 0.60}, {0.40, 0.36}, STROKE))
		return nearer(d, capsule(p, {0.40, 0.60}, {0.64, 0.60}, STROKE))
	}
	d = nearer(d, capsule(p, {0.84, 0.16}, {0.60, 0.16}, STROKE))
	return nearer(d, capsule(p, {0.84, 0.16}, {0.84, 0.40}, STROKE))
}

// A monitor: the outline of a screen on a short stand.
@(private = "file")
monitor :: proc(p: Point) -> f32 {
	STROKE :: 0.085
	d := abs(rounded_box(p, {0.5, 0.40}, {0.39, 0.27}, 0.07)) - STROKE / 2
	d = nearer(d, capsule(p, {0.5, 0.67}, {0.5, 0.83}, STROKE))
	d = nearer(d, capsule(p, {0.30, 0.85}, {0.70, 0.85}, STROKE))
	return d
}

// A paperclip leaning to the right. It has a long loop with a shorter loop
// inside it that is open at the bottom, where the wire ends.
@(private = "file")
paperclip :: proc(p: Point) -> f32 {
	STROKE :: 0.08
	// Rotated around the middle so the clip leans.
	ANGLE :: 0.6
	c, s := f32(0.8253356), f32(0.5646425) // cos and sin of ANGLE
	d := p - Point{0.5, 0.5}
	q := Point{d.x * c + d.y * s, -d.x * s + d.y * c} + Point{0.5, 0.5}
	outer := abs(rounded_box(q, {0.5, 0.5}, {0.15, 0.40}, 0.15)) - STROKE / 2
	inner := abs(rounded_box(q, {0.5, 0.42}, {0.075, 0.27}, 0.075)) - STROKE / 2
	// The inner loop stops short of the bottom.
	inner = max(inner, q.y - 0.62)
	return nearer(outer, inner)
}

// An archive: a sheet with a zipper down its middle, whose teeth alternate
// from side to side.
@(private = "file")
archive :: proc(p: Point) -> f32 {
	STROKE :: 0.085
	d := abs(rounded_box(p, {0.5, 0.5}, {0.30, 0.40}, 0.05)) - STROKE / 2
	for i in 0 ..< 5 {
		y := 0.22 + f32(i) * 0.09
		x := f32(0.44) if i % 2 == 0 else 0.56
		d = nearer(d, rounded_box(p, {x, y}, {0.06, 0.025}, 0.01))
	}
	// The zipper pull, at the bottom of the teeth.
	return nearer(d, rounded_box(p, {0.5, 0.71}, {0.07, 0.07}, 0.02))
}

// A picture: a frame with a hill in it and the sun over the hill.
@(private = "file")
picture :: proc(p: Point) -> f32 {
	STROKE :: 0.085
	d := abs(rounded_box(p, {0.5, 0.5}, {0.36, 0.30}, 0.06)) - STROKE / 2
	hill := triangle(p, {0.22, 0.74}, {0.46, 0.42}, {0.70, 0.74})
	d = nearer(d, hill)
	d = nearer(d, triangle(p, {0.52, 0.74}, {0.66, 0.54}, {0.80, 0.74}))
	return nearer(d, disc(p, {0.68, 0.34}, 0.07))
}

// A video: a frame with a play button in it.
@(private = "file")
video :: proc(p: Point) -> f32 {
	STROKE :: 0.085
	d := abs(rounded_box(p, {0.5, 0.5}, {0.36, 0.30}, 0.06)) - STROKE / 2
	return nearer(d, triangle(p, {0.42, 0.34}, {0.66, 0.5}, {0.42, 0.66}))
}

// A video camera seen from the side: an outlined body, and its lens as a cone
// widening to the right.
@(private = "file")
video_camera :: proc(p: Point) -> f32 {
	STROKE :: 0.085
	d := abs(rounded_box(p, {0.38, 0.5}, {0.26, 0.21}, 0.06)) - STROKE / 2
	return nearer(d, triangle(p, {0.69, 0.5}, {0.90, 0.32}, {0.90, 0.68}))
}

// A text file: a sheet with a folded corner and lines of text on it.
@(private = "file")
text_file :: proc(p: Point) -> f32 {
	STROKE :: 0.07
	d := document(p)
	d = nearer(d, capsule(p, {0.34, 0.46}, {0.66, 0.46}, STROKE))
	d = nearer(d, capsule(p, {0.34, 0.60}, {0.66, 0.60}, STROKE))
	return nearer(d, capsule(p, {0.34, 0.74}, {0.56, 0.74}, STROKE))
}

// Saving: an arrow pointing down into an open tray.
@(private = "file")
download :: proc(p: Point) -> f32 {
	STROKE :: 0.09
	d := capsule(p, {0.5, 0.12}, {0.5, 0.58}, STROKE)
	d = nearer(d, triangle(p, {0.30, 0.48}, {0.70, 0.48}, {0.5, 0.70}))
	d = nearer(d, capsule(p, {0.16, 0.66}, {0.16, 0.86}, STROKE))
	d = nearer(d, capsule(p, {0.16, 0.86}, {0.84, 0.86}, STROKE))
	d = nearer(d, capsule(p, {0.84, 0.66}, {0.84, 0.86}, STROKE))
	return d
}

// A magnifying glass: a ring with its handle going down to the right.
@(private = "file")
magnifier :: proc(p: Point) -> f32 {
	STROKE :: 0.09
	d := abs(rounded_box(p, {0.42, 0.42}, {0.24, 0.24}, 0.24)) - STROKE / 2
	return nearer(d, capsule(p, {0.60, 0.60}, {0.82, 0.82}, 0.12))
}

// A page of the log: a frame around three lines of text of different
// lengths.
@(private = "file")
log_page :: proc(p: Point) -> f32 {
	STROKE :: 0.085
	d := abs(rounded_box(p, {0.5, 0.5}, {0.36, 0.38}, 0.07)) - STROKE / 2
	d = nearer(d, capsule(p, {0.32, 0.35}, {0.68, 0.35}, STROKE))
	d = nearer(d, capsule(p, {0.32, 0.50}, {0.60, 0.50}, STROKE))
	d = nearer(d, capsule(p, {0.32, 0.65}, {0.66, 0.65}, STROKE))
	return d
}

// An eye: the outline of a lens, which is where two big discs (one above the
// other) overlap, with the pupil inside it.
@(private = "file")
eye :: proc(p: Point) -> f32 {
	STROKE :: 0.085
	lens := max(disc(p, {0.5, 0.77}, 0.45), disc(p, {0.5, 0.23}, 0.45))
	d := abs(lens) - STROKE / 2
	return nearer(d, disc(p, {0.5, 0.5}, 0.11))
}

// Replying in a thread: a line going down from the top left that bends
// around into an arrow pointing right, like the ↪ symbol.
@(private = "file")
hooked_arrow :: proc(p: Point) -> f32 {
	STROKE :: 0.1
	d := capsule(p, {0.22, 0.16}, {0.22, 0.42}, STROKE)
	// The bend, which is the bottom left quarter of a ring.
	bend := max(arc(p, {0.44, 0.42}, 0.22, STROKE, .Bottom, 0.42), p.x - 0.44)
	d = nearer(d, bend)
	d = nearer(d, capsule(p, {0.44, 0.64}, {0.66, 0.64}, STROKE))
	return nearer(d, triangle(p, {0.62, 0.46}, {0.86, 0.64}, {0.62, 0.82}))
}

// A pencil leaning to the right with its point at the bottom left. It
// consists of the body and, a little apart from it, the point.
@(private = "file")
pencil :: proc(p: Point) -> f32 {
	d := capsule(p, {0.42, 0.58}, {0.78, 0.22}, 0.2)
	return nearer(d, triangle(p, {0.239, 0.619}, {0.381, 0.761}, {0.14, 0.86}))
}

// A smiling face: a ring with two eyes and a smile.
@(private = "file")
smiley :: proc(p: Point) -> f32 {
	STROKE :: 0.085
	d := abs(rounded_box(p, {0.5, 0.5}, {0.38, 0.38}, 0.38)) - STROKE / 2
	d = nearer(d, rounded_box(p, {0.37, 0.40}, {0.05, 0.06}, 0.05))
	d = nearer(d, rounded_box(p, {0.63, 0.40}, {0.05, 0.06}, 0.05))
	d = nearer(d, capsule(p, {0.32, 0.58}, {0.42, 0.67}, STROKE))
	d = nearer(d, capsule(p, {0.42, 0.67}, {0.58, 0.67}, STROKE))
	d = nearer(d, capsule(p, {0.58, 0.67}, {0.68, 0.58}, STROKE))
	return d
}

// An upright drawing pin: a round head on a wider collar, with the point
// below.
@(private = "file")
drawing_pin :: proc(p: Point) -> f32 {
	STROKE :: 0.085
	d := rounded_box(p, {0.5, 0.26}, {0.15, 0.15}, 0.12)
	d = nearer(d, capsule(p, {0.26, 0.48}, {0.74, 0.48}, 0.13))
	d = nearer(d, capsule(p, {0.5, 0.52}, {0.5, 0.88}, STROKE))
	return d
}

// An outlined waste bin with two ribs down its side, under a lid with a
// handle on top.
@(private = "file")
bin :: proc(p: Point) -> f32 {
	STROKE :: 0.085
	d := capsule(p, {0.16, 0.24}, {0.84, 0.24}, STROKE)
	handle := abs(rounded_box(p, {0.5, 0.18}, {0.12, 0.07}, 0.04)) - STROKE / 2
	d = nearer(d, max(handle, p.y - 0.22))
	d = nearer(d, abs(rounded_box(p, {0.5, 0.62}, {0.24, 0.24}, 0.06)) - STROKE / 2)
	d = nearer(d, capsule(p, {0.42, 0.50}, {0.42, 0.74}, STROKE))
	d = nearer(d, capsule(p, {0.58, 0.50}, {0.58, 0.74}, STROKE))
	return d
}

// Two music notes joined by a beam, with the second note a step higher.
@(private = "file")
notes :: proc(p: Point) -> f32 {
	STROKE :: 0.085
	BEAM :: 0.13
	HEAD :: 0.13
	// Each stem rises from the right side of its head to the beam.
	d := disc(p, {0.28, 0.76}, HEAD)
	d = nearer(d, disc(p, {0.70, 0.68}, HEAD))
	d = nearer(d, capsule(p, {0.37, 0.76}, {0.37, 0.24}, STROKE))
	d = nearer(d, capsule(p, {0.79, 0.68}, {0.79, 0.16}, STROKE))
	d = nearer(d, capsule(p, {0.37, 0.24}, {0.79, 0.16}, BEAM))
	return d
}

// An outlined sheet of paper with its top right corner folded over.
@(private = "file")
document :: proc(p: Point) -> f32 {
	STROKE :: 0.085
	FOLD :: 0.22
	sheet := abs(rounded_box(p, {0.5, 0.5}, {0.30, 0.40}, 0.05)) - STROKE / 2
	// The corner is removed from the outline...
	corner := edge(p, {0.80 - FOLD, 0.10}, {0.80, 0.10 + FOLD})
	sheet = max(sheet, corner - STROKE / 2)
	// ...and drawn folded, as the diagonal and the flap's two edges.
	d := nearer(sheet, capsule(p, {0.80 - FOLD, 0.10}, {0.80, 0.10 + FOLD}, STROKE))
	d = nearer(d, capsule(p, {0.80 - FOLD, 0.10}, {0.80 - FOLD, 0.10 + FOLD}, STROKE))
	d = nearer(d, capsule(p, {0.80 - FOLD, 0.10 + FOLD}, {0.80, 0.10 + FOLD}, STROKE))
	return d
}

// A person from the chest up: a head over rounded shoulders, with a gap
// between the two.
@(private = "file")
person :: proc(p, head: Point, size: f32) -> f32 {
	h := disc(p, head, 0.15 * size)
	body := rounded_box(p, head + {0, 0.40 * size}, {0.28 * size, 0.19 * size}, 0.17 * size)
	body = cut(body, disc(p, head, (0.15 + 0.07) * size))
	return nearer(h, body)
}

// Two people, with one a little behind the other, for buddies.
@(private = "file")
two_people :: proc(p: Point) -> f32 {
	front := person(p, {0.40, 0.33}, 1)
	behind := person(p, {0.68, 0.26}, 0.85)
	// The person behind is hidden where the front person stands, with a gap
	// so that the two can be told apart.
	behind = cut(behind, front - 0.07)
	behind = max(behind, p.y - 0.83) // and the person behind stands on the same ground
	return nearer(front, behind)
}

// One person
@(private = "file")
one_person :: proc(p: Point) -> f32 {
	return person(p, {0.40, 0.33}, 1)
}

// A microphone: the capsule you talk into, the bracket under it, and a
// stand.
@(private = "file")
microphone :: proc(p: Point) -> f32 {
	STROKE :: 0.085
	d := capsule(p, {0.5, 0.21}, {0.5, 0.45}, 0.26)
	d = nearer(d, arc(p, {0.5, 0.42}, 0.28, STROKE, .Bottom, 0.42))
	d = nearer(d, capsule(p, {0.5, 0.70}, {0.5, 0.85}, STROKE))
	d = nearer(d, capsule(p, {0.34, 0.85}, {0.66, 0.85}, STROKE))
	return d
}

// A speaker: a box with a cone opening to the right. The crossed-out version
// omits the sound waves and has the line instead, which is plainer than
// crossing out the waves as well.
@(private = "file")
speaker :: proc(p: Point) -> f32 {
	d := rounded_box(p, {0.22, 0.5}, {0.09, 0.12}, 0.035)
	d = nearer(d, triangle(p, {0.52, 0.16}, {0.52, 0.84}, {0.22, 0.5}))
	return d
}

// The sound waves coming out of the speaker: two arcs, open to the right.
@(private = "file")
speaker_sound :: proc(p: Point) -> f32 {
	// Cut well clear of the cone. Otherwise the near ends of the arcs would
	// run into it and the three would read as one shape.
	CLEAR :: 0.58
	d := arc(p, {0.44, 0.5}, 0.25, 0.08, .Right, CLEAR)
	d = nearer(d, arc(p, {0.44, 0.5}, 0.39, 0.08, .Right, CLEAR))
	return d
}

// Three sliders, each with its handle in a different place.
@(private = "file")
sliders :: proc(p: Point) -> f32 {
	TRACK :: 0.075
	KNOB :: 0.115
	rows := [3]f32{0.24, 0.5, 0.76}
	handles := [3]f32{0.66, 0.36, 0.58}
	d := f32(1)
	for y, i in rows {
		// A gap around the handle so the track and the handle can be told
		// apart.
		track := capsule(p, {0.13, y}, {0.87, y}, TRACK)
		track = cut(track, disc(p, {handles[i], y}, KNOB + SLASH_GAP / 2))
		d = nearer(d, track)
		d = nearer(d, disc(p, {handles[i], y}, KNOB))
	}
	return d
}

// A paper dart that points in the direction the message goes: a triangle with
// a notch taken out of its back.
@(private = "file")
dart :: proc(p: Point) -> f32 {
	d := triangle(p, {0.09, 0.12}, {0.93, 0.5}, {0.09, 0.88})
	// The notch reaches past the back of the dart so the two edges do not
	// land on each other and leave a seam.
	return cut(d, triangle(p, {0.02, 0.06}, {0.38, 0.5}, {0.02, 0.94}))
}

// crossed_out draws a line across an icon, with a gap where it crosses.
@(private = "file")
crossed_out :: proc(d: f32, p: Point) -> f32 {
	gapped := cut(d, capsule(p, SLASH_FROM, SLASH_TO, SLASH_WIDTH + 2 * SLASH_GAP))
	return nearer(gapped, capsule(p, SLASH_FROM, SLASH_TO, SLASH_WIDTH))
}

@(private = "file")
nearer :: proc(a, b: f32) -> f32 {
	return min(a, b)
}

// cut takes `hole` out of `d`. What is left is inside `d` and outside `hole`.
@(private = "file")
cut :: proc(d, hole: f32) -> f32 {
	return max(d, -hole)
}

@(private = "file")
disc :: proc(p, centre: Point, radius: f32) -> f32 {
	return length(p - centre) - radius
}

// A line from a to b with rounded ends that is `width` wide.
@(private = "file")
capsule :: proc(p, a, b: Point, width: f32) -> f32 {
	pa, ba := p - a, b - a
	along := clamp(dot(pa, ba) / dot(ba, ba), 0, 1)
	return length(pa - ba * along) - width / 2
}

@(private = "file")
rounded_box :: proc(p, centre, half: Point, radius: f32) -> f32 {
	q := Point{abs(p.x - centre.x), abs(p.y - centre.y)} - half + radius
	outside := Point{max(q.x, 0), max(q.y, 0)}
	return length(outside) + min(max(q.x, q.y), 0) - radius
}

@(private = "file")
Half :: enum {
	Top,
	Bottom,
	Right,
}

// Part of a ring that is `width` wide. Only the part that lies past the line
// `cut`, on the side that `half` names, is kept.
@(private = "file")
arc :: proc(p, centre: Point, radius, width: f32, half: Half, cut: f32) -> f32 {
	ring := abs(length(p - centre) - radius) - width / 2
	beyond: f32
	switch half {
	case .Top:
		beyond = p.y - cut
	case .Bottom:
		beyond = cut - p.y
	case .Right:
		beyond = cut - p.x
	}
	return max(ring, beyond)
}

// A triangle: the area inside all three of its edges, with corners that are
// accurate enough for an icon. The corners go clockwise.
@(private = "file")
triangle :: proc(p, a, b, c: Point) -> f32 {
	return max(edge(p, a, b), edge(p, b, c), edge(p, c, a))
}

// How far p is to the right of the line from a to b (with y pointing down).
@(private = "file")
edge :: proc(p, a, b: Point) -> f32 {
	normal := Point{b.y - a.y, a.x - b.x}
	l := length(normal)
	if l == 0 {
		return length(p - a)
	}
	return dot(p - a, normal / l)
}

@(private = "file")
length :: proc(v: Point) -> f32 {
	return math.sqrt(v.x * v.x + v.y * v.y)
}

@(private = "file")
dot :: proc(a, b: Point) -> f32 {
	return a.x * b.x + a.y * b.y
}
