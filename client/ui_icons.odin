package client

import "core:math"
import mu "vendor:microui"

/*
The UI's icons, without an icon font to ship: each one is a handful of
shapes - discs, capsules, rounded boxes, arcs - written down as distance
functions over a unit square and rasterized into an alpha atlas, the way
ui_font.odin rasterizes glyphs. Coverage comes from the distance, so the
edges are smooth, and the atlas is rebuilt at the display's density
whenever the scale changes, so they stay sharp on high-DPI screens.

The atlas holds one alpha channel, like the font's, so the shader paints
an icon in whatever colour it's drawn with: icons take the colour of the
text they stand next to.

Icons reach the renderer as microui icon commands whose ids are offset
by UI_ICON_BASE; ui_render.odin takes them apart again.
*/

Icon :: enum {
	Mic, // a microphone: someone who can be heard
	Mic_Off, // muted: a microphone with a line through it
	Sound, // a speaker with sound coming out: hearing the others
	Sound_Off, // deafened: a speaker with a line through it
	Settings, // sliders
	Leave, // a power symbol: disconnect
	Send, // a paper dart: post what's in the chat box
}

// Icon command ids start here, above microui's own icons and below the
// chat images' (IMAGE_ICON_BASE, ui_images.odin).
UI_ICON_BASE :: 100

// Logical pixels. Icons are square and drawn at this size everywhere, so
// one atlas at one size does for all of them.
ICON_SIZE :: 16
// A button with nothing but an icon on it is this wide.
ICON_BUTTON :: 30

// What the state icons are coloured with: green for a voice coming
// through, red for something switched off, grey for a quiet channel.
SPEAKING_COLOR :: mu.Color{110, 220, 110, 255}
OFF_COLOR :: mu.Color{225, 115, 115, 255}
DIM_COLOR :: mu.Color{140, 140, 140, 255}

// The id to draw this icon with (mu.draw_icon, icon_button).
icon_id :: proc(icon: Icon) -> mu.Icon {
	return mu.Icon(UI_ICON_BASE + int(icon))
}

Icon_Atlas :: struct {
	scale:  f32, // physical pixels per logical pixel it was built for
	side:   i32, // one icon's side, in physical pixels
	width:  i32,
	height: i32,
	pixels: []u8, // width * height, one alpha byte per texel
}

/*
icon_atlas_build rasterizes every icon side by side at `scale`. It
returns false, and leaves the atlas alone, if nothing came of it, so the
caller can keep drawing with what it already has.
*/
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
				// The texel's centre, in the unit square the shapes are
				// written in.
				p := Point{(f32(x) + 0.5) / f32(side), (f32(y) + 0.5) / f32(side)}
				d := icon_distance(icon, p) * f32(side) // texels, not units
				// One texel of coverage across the edge.
				alpha := clamp(0.5 - d, 0, 1)
				pixels[y * int(width) + left + x] = u8(math.round(alpha * 255))
			}
		}
	}

	delete(a.pixels)
	a.scale, a.side, a.width, a.height, a.pixels = scale, side, width, height, pixels
	return true
}

icon_atlas_destroy :: proc(a: ^Icon_Atlas) {
	delete(a.pixels)
	a^ = {}
}

/*
The shapes. Every icon lives in the unit square with y downwards, and
each proc returns the signed distance to its outline: negative inside,
positive outside, in the same units. Shapes are combined by taking the
nearer of two (union) or by cutting one out of the other.
*/

@(private = "file")
Point :: [2]f32

// Where the line through a muted icon runs, how wide it is, and how much
// of a gap it leaves around itself: the line is cut out of the icon
// first, so it reads as a line rather than as more of the same shape.
@(private = "file")
SLASH_FROM :: Point{0.15, 0.13}
@(private = "file")
SLASH_TO :: Point{0.85, 0.87}
@(private = "file")
SLASH_WIDTH :: 0.09
@(private = "file")
SLASH_GAP :: 0.045

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
	case .Leave:
		return power(p)
	case .Send:
		return dart(p)
	}
	return 1
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

/*
A speaker: a box with a cone opening to the right. The crossed-out one
drops the sound coming out of it and takes the line instead, which is
plainer than crossing out the waves as well.
*/
@(private = "file")
speaker :: proc(p: Point) -> f32 {
	d := rounded_box(p, {0.22, 0.5}, {0.09, 0.12}, 0.035)
	d = nearer(d, triangle(p, {0.52, 0.16}, {0.52, 0.84}, {0.22, 0.5}))
	return d
}

// The waves coming out of it: two arcs, open to the right.
@(private = "file")
speaker_sound :: proc(p: Point) -> f32 {
	// Cut well clear of the cone, or the near ends of the arcs would run
	// into it and the three would read as one shape.
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
		// A gap around the handle, so track and handle read apart.
		track := capsule(p, {0.13, y}, {0.87, y}, TRACK)
		track = cut(track, disc(p, {handles[i], y}, KNOB + SLASH_GAP / 2))
		d = nearer(d, track)
		d = nearer(d, disc(p, {handles[i], y}, KNOB))
	}
	return d
}

// The power symbol: a ring broken at the top, with a bar standing in
// the break.
@(private = "file")
power :: proc(p: Point) -> f32 {
	STROKE :: 0.105
	ring := abs(length(p - {0.5, 0.57}) - 0.30) - STROKE / 2
	ring = cut(ring, rounded_box(p, {0.5, 0.20}, {0.11, 0.16}, 0))
	return nearer(ring, capsule(p, {0.5, 0.13}, {0.5, 0.45}, STROKE))
}

// A paper dart, pointing the way the message goes: a triangle with a
// notch taken out of its back.
@(private = "file")
dart :: proc(p: Point) -> f32 {
	d := triangle(p, {0.09, 0.12}, {0.93, 0.5}, {0.09, 0.88})
	// The notch reaches past the back of the dart, so the two edges
	// don't land on each other and leave a seam.
	return cut(d, triangle(p, {0.02, 0.06}, {0.38, 0.5}, {0.02, 0.94}))
}

// crossed_out puts a line across an icon, with a gap where it crosses.
@(private = "file")
crossed_out :: proc(d: f32, p: Point) -> f32 {
	gapped := cut(d, capsule(p, SLASH_FROM, SLASH_TO, SLASH_WIDTH + 2 * SLASH_GAP))
	return nearer(gapped, capsule(p, SLASH_FROM, SLASH_TO, SLASH_WIDTH))
}

@(private = "file")
nearer :: proc(a, b: f32) -> f32 {
	return min(a, b)
}

// cut takes `hole` out of `d`: what's left is inside `d` and outside it.
@(private = "file")
cut :: proc(d, hole: f32) -> f32 {
	return max(d, -hole)
}

@(private = "file")
disc :: proc(p, centre: Point, radius: f32) -> f32 {
	return length(p - centre) - radius
}

// A line from a to b with rounded ends, `width` across.
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

// Part of a ring, `width` across: only what lies past the line `cut`,
// on the side `half` names.
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

// A triangle: the space inside all three of its edges, with the corners
// they meet at near enough for an icon. Corners go clockwise.
@(private = "file")
triangle :: proc(p, a, b, c: Point) -> f32 {
	return max(edge(p, a, b), edge(p, b, c), edge(p, c, a))
}

// How far p is to the right of the line from a to b (y downwards).
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
