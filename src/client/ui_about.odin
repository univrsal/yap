package client

import "core:fmt"
import "core:strings"
import mu "vendor:microui"

import "client:platform"
import "common:."

/*
The About category of the settings page: which build this is (see
src/common/version.odin), and the third-party software in it with their
licenses, one collapsible header each.

The license texts are in licenses/, compiled in.
*/

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
		name = "tinydialogs",
		license = "MIT or Unlicense",
		use = "The file dialog, for sending files",
		text = #load("licenses/tinydialogs.txt", string),
		builds = {.Desktop},
	},
	{
		name = "tinyaac",
		license = "Unlicense or MIT",
		use = "Capturing an application's audio, for sharing it",
		text = #load("licenses/tinyaac.txt", string),
		builds = {.Desktop},
	},
	{
		name = "Roboto",
		license = "Apache-2.0",
		use = "The font, regular, bold and italic (font data copyright Google 2012)",
		url = "https://fonts.google.com/specimen/Roboto",
		text = #load("licenses/roboto.txt", string),
		builds = {.Desktop, .Web},
	},
	{
		name = "JetBrains Mono",
		license = "OFL-1.1",
		use = "The font for code in messages",
		url = "https://www.jetbrains.com/lp/mono/",
		text = #load("licenses/jetbrainsmono.txt", string),
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
		name = "Noto Emoji",
		license = "OFL-1.1",
		use = "Emoji, drawn like text (a cut-down copy: scripts/emoji.py)",
		url = "https://fonts.google.com/noto/specimen/Noto+Emoji",
		text = #load("licenses/notoemoji.txt", string),
		builds = {.Desktop, .Web},
	},
	{
		name = "gemoji",
		license = "MIT",
		use = "The list of emoji and their shortcodes",
		url = "https://github.com/github/gemoji",
		text = #load("licenses/gemoji.txt", string),
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

// about_settings fills the settings page's right-hand panel.
about_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	mu.layout_row(ctx, {-1})
	mu.label(ctx, fmt.tprintf("yap %s", common.version_string()))
	about_text(
		ctx,
		"A sloppy, minimal and limited VOIP application.\nhttps://github.com/univrsal/yap",
	)

	mu.label(ctx, "")
	mu.label(ctx, "Third-party software (click one for its license):")
	build := Build.Web if platform.WEB else Build.Desktop
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
		about_text(
			ctx,
			fmt.tprintf("%s.\n%s", p.use, p.url) if p.url != "" else fmt.tprintf("%s.", p.use),
		)
		mu.label(ctx, "")
		with_text_color(ctx, theme.dim, p.text, about_text)
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
