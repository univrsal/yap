package client

import "core:fmt"
import "core:strings"
import mu "vendor:microui"

import "../common"

/*
The About dialog: which build this is (see src/common/version.odin), and
the third-party software in it with their licenses, one collapsible
header each. It floats above everything else, like the image viewer
(ui_images.odin), and is opened from the settings page.

The license texts are in licenses/, compiled in.
*/

ABOUT_WINDOW :: "About yap"

@(private = "file")
Build :: enum {
	Desktop,
	Web,
}

@(private = "file")
Third_Party :: struct {
	name:    string,
	license: string, // its short name
	use:     string, // what yap uses it for
	url:     string,
	text:    string, // the license in full
	builds:  bit_set[Build],
}

@(private = "file")
THIRD_PARTY := [?]Third_Party {
	{
		name = "Odin core library",
		license = "zlib",
		use = "Networking, the Noise handshake's cryptography, JSON and more",
		url = "https://odin-lang.org",
		text = #load("licenses/odin.txt", string),
		builds = {.Desktop, .Web},
	},
	{
		name = "microui",
		license = "MIT",
		use = "The user interface (Odin's port of it)",
		url = "https://github.com/rxi/microui",
		text = #load("licenses/microui.txt", string),
		builds = {.Desktop, .Web},
	},
	{
		name = "GLFW",
		license = "zlib",
		use = "The window, its input and the clipboard",
		url = "https://www.glfw.org",
		text = #load("licenses/glfw.txt", string),
		builds = {.Desktop},
	},
	{
		name = "stb_image and stb_truetype",
		license = "MIT or public domain",
		use = "Reading images in chat, and drawing text",
		url = "https://github.com/nothings/stb",
		text = #load("licenses/stb.txt", string),
		builds = {.Desktop, .Web},
	},
	{
		name = "miniaudio",
		license = "public domain or MIT No Attribution",
		use = "Microphones, speakers and headphones",
		url = "https://miniaud.io",
		text = #load("licenses/miniaudio.txt", string),
		builds = {.Desktop, .Web},
	},
	{
		name = "Opus",
		license = "BSD-3-Clause",
		use = "The voice codec, and the notification sounds' format",
		url = "https://opus-codec.org",
		text = #load("licenses/opus.txt", string),
		builds = {.Desktop, .Web},
	},
	{
		name = "RNNoise",
		license = "BSD-3-Clause",
		use = "Noise suppression",
		url = "https://github.com/xiph/rnnoise",
		text = #load("licenses/rnnoise.txt", string),
		builds = {.Desktop, .Web},
	},
	{
		name = "traycon",
		license = "BSD-3-Clause",
		use = "The tray icon",
		url = "https://github.com/univrsal/traycon",
		text = #load("licenses/traycon.txt", string),
		builds = {.Desktop},
	},
	{
		name = "Roboto",
		license = "Apache-2.0",
		use = "The font (font data copyright Google 2012)",
		url = "https://fonts.google.com/specimen/Roboto",
		text = #load("licenses/roboto.txt", string),
		builds = {.Desktop, .Web},
	},
	{
		name = "GNU Unifont",
		license = "OFL-1.1 or GPL-2.0-or-later with the font embedding exception",
		use = "The fallback font, for characters Roboto doesn't have",
		url = "https://unifoundry.com/unifont/",
		text = #load("licenses/unifont.txt", string),
		builds = {.Desktop, .Web},
	},
	{
		name = "Emscripten",
		license = "MIT or University of Illinois/NCSA",
		use = "The web build's runtime",
		url = "https://emscripten.org",
		text = #load("licenses/emscripten.txt", string),
		builds = {.Web},
	},
}

UI_About :: struct {
	open:   bool,
	placed: bool, // centred since it was opened
}

open_about :: proc(ui: ^UI) {
	ui.about = {open = true}
}

about_dialog :: proc(ui: ^UI, window_w, window_h: i32) {
	a := &ui.about
	if !a.open {
		return
	}
	ctx := &ui.ctx
	// Open it centred, as big as fits up to a comfortable reading width.
	if !a.placed {
		a.placed = true
		w := clamp(window_w - 40, 240, 600)
		h := max(window_h - 40, 200)
		if cnt := mu.get_container(ctx, ABOUT_WINDOW); cnt != nil {
			cnt.rect = {(window_w - w) / 2, (window_h - h) / 2, w, h}
			cnt.open = true
			cnt.scroll = {}
			mu.bring_to_front(ctx, cnt)
			// The click that opened it would raise the window behind at
			// the end of the frame (see image_viewer).
			ctx.hover_root, ctx.next_hover_root = cnt, cnt
		}
	}
	if cnt := mu.get_container(ctx, ABOUT_WINDOW, {.CLOSED});
	   cnt != nil && cnt.open && cnt.zindex != ctx.last_zindex {
		mu.bring_to_front(ctx, cnt)
	}
	if !mu.begin_window(ctx, ABOUT_WINDOW, {}) {
		a.open = false // closed with the title bar's button
		return
	}
	defer mu.end_window(ctx)

	mu.layout_row(ctx, {-90, -1})
	mu.label(ctx, fmt.tprintf("yap %s", common.version_string()))
	if .SUBMIT in mu.button(ctx, "Close") {
		a.open = false
		if cnt := mu.get_current_container(ctx); cnt != nil {
			cnt.open = false
		}
	}
	mu.layout_row(ctx, {-1})
	about_text(ctx, "A sloppy, minimal and limited VOIP application.\nhttps://github.com/univrsal/yap")

	mu.label(ctx, "")
	mu.label(ctx, "Third-party software (click one for its license):")
	build := Build.Web if WEB else Build.Desktop
	for &p, i in THIRD_PARTY {
		if build not_in p.builds {
			continue
		}
		mu.push_id(ctx, uintptr(i))
		defer mu.pop_id(ctx)
		mu.layout_row(ctx, {-1})
		// Collapsed until clicked: the licenses are long.
		if .ACTIVE not_in mu.header(ctx, fmt.tprintf("%s  (%s)", p.name, p.license)) {
			continue
		}
		about_text(ctx, fmt.tprintf("%s.\n%s", p.use, p.url))
		mu.label(ctx, "")
		with_text_color(ctx, DIM_COLOR, p.text, about_text)
	}
}

/*
about_text is mu.text, a line at a time: mu.text wraps long lines, but
draws the newline that ends one as well (a missing glyph), and an empty
line takes no room at all.
*/
@(private = "file")
about_text :: proc(ctx: ^mu.Context, text: string) {
	// Lines as close together as mu.text's own wrapped ones.
	saved_spacing := ctx.style.spacing
	ctx.style.spacing = 0
	defer ctx.style.spacing = saved_spacing

	rest := strings.trim_right(text, "\n")
	for line in strings.split_lines_iterator(&rest) {
		if strings.trim_space(line) == "" {
			mu.label(ctx, "")
		} else {
			mu.text(ctx, line)
		}
	}
}
