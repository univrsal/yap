/*
The client's text areas as the page's own text fields (see
src/client/ui_field_web.odin), run before the client starts (emcc
--pre-js, see web/build.sh), so that its key listeners come before GLFW's.

A text box the client draws on the canvas is only pixels to the browser:
no spell checking, and on a phone no magnifier, selection handles or caret
moved with the space bar. So every text area the client lays out has a
<textarea> laid over it, transparent but for its text, which draws and
edits the text in the client's font and colors. Whatever is done in it is
handed to the client as the whole text and selection, and the client hands
back what it changes itself (completing a word, sending, ...).

Of the keys typed in a field, the client still gets the ones its
composers act on (forward); the rest are the field's alone, since GLFW
listens on the whole window and would act on them a second time.
*/
(() => {
	const fields = new Map(); // by the client's id: {id, el, seen, lines, ...}
	const encoder = new TextEncoder();
	let family = "sans-serif";

	const ready = () => typeof Module._web_field_input === "function";

	// The client counts in bytes of UTF-8, a string in UTF-16 units.
	const toBytes = (s, i) => encoder.encode(s.slice(0, i)).length;
	const toIndex = (s, bytes) => {
		let i = 0;
		for (let b = 0; i < s.length && b < bytes; ) {
			const c = s.codePointAt(i);
			b += c < 0x80 ? 1 : c < 0x800 ? 2 : c < 0x10000 ? 3 : 4;
			i += c > 0xffff ? 2 : 1;
		}
		return i;
	};
	const rgba = (c) => `rgba(${c >>> 24}, ${(c >>> 16) & 255}, ${(c >>> 8) & 255}, ${(c & 255) / 255})`;

	const fieldOf = (el) =>
		el instanceof HTMLTextAreaElement && el.dataset.yapField !== undefined
			? fields.get(Number(el.dataset.yapField))
			: undefined;

	// The text and selection (the caret, then where it started) to the
	// client, unless that is what the two last agreed on (f.agreed): when
	// the client sets the selection, the field says so too, later, by which
	// time the client may have moved it again.
	const send = (f) => {
		if (!ready()) return;
		const el = f.el;
		const text = el.value;
		const start = toBytes(text, el.selectionStart);
		const end = el.selectionEnd === el.selectionStart ? start : toBytes(text, el.selectionEnd);
		const [caret, anchor] = el.selectionDirection === "backward" ? [start, end] : [end, start];
		const a = f.agreed;
		if (a.text === text && a.caret === caret && a.anchor === anchor) return;
		f.agreed = { text, caret, anchor };
		const bytes = encoder.encode(text);
		const ptr = _malloc(bytes.length + 1);
		HEAPU8.set(bytes, ptr);
		Module._web_field_input(f.id, ptr, bytes.length, caret, anchor);
		_free(ptr);
	};

	// How many lines the text wraps into at the field's width, for the client
	// to make the box that tall.
	const measure = (f) => {
		const el = f.el;
		if (!f.line || el.style.display === "none") return;
		const height = el.style.height;
		const scroll = el.scrollTop;
		el.style.height = "0px";
		const n = Math.max(1, Math.round((el.scrollHeight - f.padTop - f.padBottom) / f.line));
		el.style.height = height;
		el.scrollTop = scroll;
		if (n !== f.lines) {
			f.lines = n;
			if (ready()) Module._web_field_lines(f.id, n);
		}
	};

	const select = (f, caret, anchor) => {
		const text = f.el.value;
		f.agreed = { text, caret, anchor };
		if (f.composing) return;
		const c = toIndex(text, caret);
		const a = toIndex(text, anchor);
		f.el.setSelectionRange(Math.min(c, a), Math.max(c, a), c < a ? "backward" : "forward");
	};

	// Puts a field where its text area is on the canvas (f.x, f.y), counted
	// from where the page put the canvas (index.html, fit) rather than from
	// getBoundingClientRect: both are fixed to the layout viewport, which on
	// iOS isn't what client coordinates count from while the keyboard is up.
	const position = (f) => {
		const c = Module.canvas.style;
		f.el.style.left = `${(parseFloat(c.left) || 0) + f.x}px`;
		f.el.style.top = `${(parseFloat(c.top) || 0) + f.y}px`;
	};

	// When a phone's keyboard comes up, iOS also scrolls the page, and the
	// canvas is moved down to stay in sight (index.html). Its size doesn't
	// change, so the client draws no frame to place the fields again: they
	// follow it here, once the page's own listeners (which come later) have
	// moved it.
	const follow = () =>
		requestAnimationFrame(() => {
			for (const f of fields.values()) if (f.el.style.display !== "none") position(f);
		});
	window.addEventListener("resize", follow);
	window.visualViewport?.addEventListener("resize", follow);
	window.visualViewport?.addEventListener("scroll", follow);

	const hide = (f) => {
		if (document.activeElement === f.el) f.el.blur();
		f.el.style.display = "none";
	};

	const create = (id) => {
		const el = document.createElement("textarea");
		el.dataset.yapField = String(id);
		el.rows = 1;
		el.spellcheck = true;
		el.setAttribute("autocapitalize", "sentences");
		el.style.cssText =
			"display:none;position:fixed;margin:0;border:0;outline:none;resize:none;" +
			"background:transparent;box-sizing:border-box;overflow-x:hidden;overflow-y:auto;" +
			"scrollbar-width:thin;white-space:pre-wrap;overflow-wrap:break-word;";
		el.style.fontFamily = family;
		document.body.appendChild(el);
		const f = { id, el, seen: false, x: 0, y: 0, lines: 0, line: 0, em: 0, width: 0, padTop: 0, padBottom: 0 };
		f.agreed = { text: "", caret: 0, anchor: 0 };
		f.enterSends = true;
		f.completing = false;
		f.composing = false;
		el.addEventListener("input", () => {
			send(f);
			measure(f);
		});
		el.addEventListener("focus", () => {
			if (ready()) Module._web_field_focus(id);
			send(f);
		});
		el.addEventListener("selectionchange", () => send(f));
		el.addEventListener("touchstart", () => ready() && Module._web_field_touched(), { passive: true });
		el.addEventListener("compositionstart", () => (f.composing = true));
		el.addEventListener("compositionend", () => (f.composing = false));
		fields.set(id, f);
		return f;
	};

	// Not every browser tells the field itself that its selection moved.
	document.addEventListener("selectionchange", () => {
		const f = fieldOf(document.activeElement);
		if (f) send(f);
	});

	// The selection's color, which only a style sheet can set.
	const style = document.createElement("style");
	style.textContent = "textarea[data-yap-field]::selection { background: var(--yap-selection); }";
	document.head.appendChild(style);

	Module.yapField = {
		font(data) {
			const face = new FontFace("yap-text", data);
			face.load().then(
				() => {
					document.fonts.add(face);
					family = '"yap-text", sans-serif';
					for (const f of fields.values()) {
						f.el.style.fontFamily = family;
						measure(f);
					}
				},
				(e) => console.error("yap: the text fields' font didn't load", e),
			);
		},

		text(id, text, caret, anchor) {
			const f = fields.get(id) || create(id);
			if (f.el.value !== text) f.el.value = text;
			select(f, caret, anchor);
			measure(f);
		},

		select(id, caret, anchor) {
			const f = fields.get(id);
			if (f) select(f, caret, anchor);
		},

		begin() {
			for (const f of fields.values()) f.seen = false;
		},

		// Puts a field over its text area: the text's part of the box is at x,
		// y, w, h, of which cx, cy, cw, ch can be seen (CSS pixels from the
		// canvas' corner).
		place(id, x, y, w, h, cx, cy, cw, ch, padX, padTop, padBottom, em, line, color, selection, flags) {
			const f = fields.get(id) || create(id);
			f.seen = true;
			const focused = (flags & 1) !== 0;
			f.enterSends = (flags & 4) !== 0;
			f.completing = (flags & 8) !== 0;
			if (flags & 2) {
				hide(f); // covered: the client draws it
				return;
			}
			const el = f.el;
			const s = el.style;
			s.display = "block";
			f.x = x;
			f.y = y;
			position(f);
			s.width = `${w}px`;
			s.height = `${h}px`;
			s.clipPath = `inset(${cy - y}px ${x + w - cx - cw}px ${y + h - cy - ch}px ${cx - x}px)`;
			s.padding = `${padTop}px ${padX}px ${padBottom}px`;
			s.fontSize = `${em}px`;
			s.lineHeight = `${line}px`;
			s.color = rgba(color);
			s.caretColor = rgba(color);
			s.setProperty("--yap-selection", rgba(selection));
			// Light text is on a dark background: a dark scrollbar.
			s.colorScheme = (color >>> 24) + ((color >>> 16) & 255) + ((color >>> 8) & 255) > 384 ? "dark" : "light";
			el.enterKeyHint = f.enterSends ? "send" : "enter";
			if (w !== f.width || em !== f.em || line !== f.line || padTop !== f.padTop || padBottom !== f.padBottom) {
				Object.assign(f, { width: w, em, line, padTop, padBottom });
				measure(f);
			}
			if (focused && document.activeElement !== el) el.focus({ preventScroll: true });
			else if (!focused && document.activeElement === el) el.blur();
		},

		end() {
			for (const f of fields.values()) if (!f.seen) hide(f);
		},
	};

	// Which keys typed in a field the client gets as well, instead of the
	// field: Enter to send (on a phone's keyboard it starts a line, and the
	// send button sends), Tab, Escape, Up in an empty field (to edit the last
	// message), Up and Down in the completion list, and the markdown keys
	// (src/client/ui.odin, key_callback). Modifiers go too, so GLFW knows
	// what is held, but do their usual work in the field as well.
	const MODIFIERS = ["Shift", "Control", "Alt", "Meta"];
	const forward = (f, e) => {
		if (e.isComposing || e.keyCode === 229) return false;
		switch (e.key) {
			case "Enter":
				return f.completing || (f.enterSends && !e.shiftKey);
			case "Tab":
			case "Escape":
				return true;
			case "ArrowUp":
				return f.completing || f.el.value === "";
			case "ArrowDown":
				return f.completing;
		}
		if (!e.ctrlKey || e.altKey || e.metaKey) return false;
		const k = e.key.toLowerCase();
		return (!e.shiftKey && k.length === 1 && "biue".includes(k)) || (e.shiftKey && k === "x");
	};

	for (const type of ["keydown", "keypress", "keyup"]) {
		window.addEventListener(
			type,
			(e) => {
				const f = fieldOf(e.target);
				if (!f || type === "keyup") return; // GLFW keeps track of what is held
				if (MODIFIERS.includes(e.key)) return;
				if (type === "keypress" || !forward(f, e)) {
					e.stopImmediatePropagation();
					return;
				}
				e.preventDefault();
			},
			true,
		);
	}
})();
