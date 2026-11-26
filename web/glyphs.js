/*
The browser's fonts, for the web client (emcc --pre-js, see web/build.sh and
src/client/render/sysglyph_web.odin, sysemoji_web.odin). A page can't read
the system's font files, but a canvas draws text with whatever the system
has for each character, falling back from font to font as the browser does
for any page, so that is used as a rasterizer: the client asks for one
character at a time, gets its pixels (and, for a symbol, how far it moves
the pen) and puts them in its own glyph atlas. Nothing is drawn with the
canvas on the page itself.

A canvas can't be asked whether a font has a character: where none does,
the browser draws its "missing character" box (a plain box in Chrome, a box
with the character's hex digits in Firefox). The probe compares the outline
of what it drew with that of a few characters that nothing has (NOTDEF) and
says "no" for a match, and the client then draws the character from
Unifont. For an emoji it also wants colour, as a font with only a black and
white outline of it isn't the emoji.

The client probes (probe), has the character drawn (render), asks how big
it came out (info) and copies the pixels out (take): an 8-bit coverage mask
for a symbol, straight RGBA for an emoji.
*/
(() => {
	const SYMBOL_FONT = "sans-serif";
	const EMOJI_FONT = '"Apple Color Emoji", "Segoe UI Emoji", "Noto Color Emoji", "Twemoji Mozilla", sans-serif';
	// Characters that no font has: the box drawn for them is the browser's.
	const NOTDEF = [0xffff, 0x10ffff, 0xfdd0];
	const SPACE = /^\p{Zs}$/u;
	// The size characters are probed at.
	const PROBE_PX = 48;

	let cv = null;
	let cx = null;
	let out = null;
	let outCx = null;

	const canvases = () => {
		if (cv) return;
		cv = document.createElement("canvas");
		cx = cv.getContext("2d", { willReadFrequently: true });
		out = document.createElement("canvas");
		outCx = out.getContext("2d", { willReadFrequently: true });
	};

	// Draws `text` at `px` with its pen at (ox, oy) on a fresh canvas and
	// finds the ink: its box relative to the pen, and the pixels.
	const ink = (text, px, font) => {
		canvases();
		const ox = Math.ceil(px);
		const oy = Math.ceil(px * 2.5);
		const W = Math.ceil(px * 4);
		const H = Math.ceil(px * 4);
		cv.width = W;
		cv.height = H;
		cx.font = `${px}px ${font}`;
		cx.textBaseline = "alphabetic";
		cx.textAlign = "left";
		cx.fillStyle = "#fff";
		cx.fillText(text, ox, oy);
		const adv = cx.measureText(text).width;
		const d = cx.getImageData(0, 0, W, H).data;
		let x0 = W, y0 = H, x1 = -1, y1 = -1;
		for (let y = 0; y < H; y++) {
			for (let x = 0; x < W; x++) {
				if (d[(y * W + x) * 4 + 3] !== 0) {
					if (x < x0) x0 = x;
					if (x > x1) x1 = x;
					if (y < y0) y0 = y;
					if (y > y1) y1 = y;
				}
			}
		}
		const blank = x1 < 0;
		return {
			adv,
			blank,
			d,
			W,
			ox,
			oy,
			// Pixel columns and rows of the ink, in the canvas.
			x0: blank ? 0 : x0,
			y0: blank ? 0 : y0,
			w: blank ? 0 : x1 - x0 + 1,
			h: blank ? 0 : y1 - y0 + 1,
		};
	};

	// The outline of the ink: which pixels of its first and last row and
	// column are on.
	const outline = (r) => {
		const on = (x, y) => r.d[((r.y0 + y) * r.W + r.x0 + x) * 4 + 3] > 64;
		const o = { w: r.w, h: r.h, rows: [], cols: [] };
		for (let x = 0; x < r.w; x++) o.rows.push(on(x, 0), on(x, r.h - 1));
		for (let y = 0; y < r.h; y++) o.cols.push(on(0, y), on(r.w - 1, y));
		return o;
	};

	const same = (a, b) =>
		a.w === b.w &&
		a.h === b.h &&
		a.rows.every((v, i) => v === b.rows[i]) &&
		a.cols.every((v, i) => v === b.cols[i]);

	const notdefs = new Map(); // font -> [outline]
	const isNotdef = (r, font) => {
		if (r.blank) return false;
		let list = notdefs.get(font);
		if (!list) {
			list = [];
			for (const cp of NOTDEF) {
				const n = ink(String.fromCodePoint(cp), PROBE_PX, font);
				if (!n.blank) list.push(outline(n));
			}
			notdefs.set(font, list);
		}
		const o = outline(r);
		return list.some((n) => same(o, n));
	};

	// Whether any pixel of the ink has a colour of its own.
	const colourful = (r) => {
		for (let y = r.y0; y < r.y0 + r.h; y++) {
			for (let x = r.x0; x < r.x0 + r.w; x++) {
				const i = (y * r.W + x) * 4;
				if (r.d[i + 3] > 128 && Math.abs(r.d[i] - r.d[i + 2]) + Math.abs(r.d[i] - r.d[i + 1]) > 40) {
					return true;
				}
			}
		}
		return false;
	};

	const textOf = (cp, emoji) => String.fromCodePoint(cp) + (emoji ? "️" : "");

	const usable = (cp) =>
		cp >= 0x20 && !(cp >= 0x7f && cp < 0xa0) && !(cp >= 0xd800 && cp < 0xe000) && cp <= 0x10ffff;

	// What the last render drew.
	let last = null;

	Module.yapGlyphs = {
		// How far a symbol moves the pen, in ems (0 or more), or -1 if the
		// browser has no font for it. For an emoji, 1 if it has a colour
		// picture of it, else -1.
		probe(cp, emoji) {
			try {
				if (!usable(cp)) return -1;
				const font = emoji ? EMOJI_FONT : SYMBOL_FONT;
				const r = ink(textOf(cp, emoji), PROBE_PX, font);
				if (emoji) {
					return !r.blank && !isNotdef(r, font) && colourful(r) ? 1 : -1;
				}
				// A blank one is only right for a space; a character that is
				// unassigned is drawn as nothing by some browsers.
				if (r.blank) return r.adv > 0 && SPACE.test(String.fromCodePoint(cp)) ? r.adv / PROBE_PX : -1;
				return isNotdef(r, font) ? -1 : r.adv / PROBE_PX;
			} catch (e) {
				return -1;
			}
		},

		// Draws a character: a symbol at `px` pixels to the em, as a mask
		// whose box is placed from the pen on the baseline; or an emoji
		// into a side x side tile with `fill` of it taken up. 1 if it worked.
		render(cp, emoji, px, side, fill) {
			try {
				if (!usable(cp)) return 0;
				if (!emoji) {
					const size = Math.max(1, Math.min(px, 256));
					const r = ink(textOf(cp, false), size, SYMBOL_FONT);
					const alpha = new Uint8Array(r.w * r.h);
					for (let y = 0; y < r.h; y++) {
						for (let x = 0; x < r.w; x++) {
							alpha[y * r.w + x] = r.d[((r.y0 + y) * r.W + r.x0 + x) * 4 + 3];
						}
					}
					last = { w: r.w, h: r.h, xoff: r.x0 - r.ox, yoff: r.y0 - r.oy, alpha };
					return 1;
				}
				const box = Math.max(1, Math.round(side * fill));
				const big = Math.max(48, Math.min(Math.round(box * 2), 192));
				const r = ink(textOf(cp, true), big, EMOJI_FONT);
				if (r.blank) return 0;
				// The square around the ink's middle that is as wide as the
				// emoji's advance (or as the ink, if that's more).
				const span = Math.max(r.adv, r.w, r.h);
				const sx = r.x0 + r.w / 2 - span / 2;
				const sy = r.y0 + r.h / 2 - span / 2;
				out.width = side;
				out.height = side;
				outCx.imageSmoothingEnabled = true;
				outCx.imageSmoothingQuality = "high";
				const at = (side - box) / 2;
				outCx.drawImage(cv, sx, sy, span, span, at, at, box, box);
				last = { w: side, h: side, xoff: 0, yoff: 0, rgba: outCx.getImageData(0, 0, side, side).data };
				return 1;
			} catch (e) {
				return 0;
			}
		},

		// 0 width, 1 height, 2 x and 3 y offset of the last render.
		info(which) {
			if (!last) return 0;
			return [last.w, last.h, last.xoff, last.yoff][which] | 0;
		},

		// Copies the last render's pixels to `ptr`, rows `stride` pixels apart.
		take(ptr, stride) {
			if (!last) return;
			if (last.rgba) {
				for (let y = 0; y < last.h; y++) {
					HEAPU8.set(last.rgba.subarray(y * last.w * 4, (y + 1) * last.w * 4), ptr + y * stride * 4);
				}
			} else {
				for (let y = 0; y < last.h; y++) {
					HEAPU8.set(last.alpha.subarray(y * last.w, (y + 1) * last.w), ptr + y * stride);
				}
			}
		},
	};
})();
