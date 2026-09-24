/*
Touch and the phone keyboard for the web client, run before the client
starts (emcc --pre-js, see web/build.sh), so its listeners come before
GLFW's.

GLFW would turn a finger into a mouse that presses wherever it lands;
the client can't use that (see src/client/ui_touch_web.odin). Instead this
tells gestures apart and hands them over:

- a tap is a click, and on a text box it also brings up the keyboard;
- a mostly vertical drag scrolls;
- a mostly sideways drag drags, for the sliders.

A phone only shows its keyboard for a real text field, and only when it
gets the focus while a tap is being handled. So there's a hidden field:
a tap on one of the client's text boxes (the client knows where they
are) focuses it, and what's typed into it is passed on and cleared
away. It always holds one invisible character, so a backspace has
something to delete - and so arrives as an edit - even when the field
looks empty.
*/
(() => {
	const canvas = Module.canvas;
	// How far a finger may wander and still be tapping, in page pixels.
	const SLOP = 10;
	// The character the hidden field keeps, and when to clear it out.
	const KEEP = "​";
	const TIDY_AT = 40;

	const ready = () => typeof Module._web_touch_tap === "function";
	const where = (touch) => {
		const r = canvas.getBoundingClientRect();
		return [touch.clientX - r.left, touch.clientY - r.top];
	};

	// ---- the hidden field ----

	const field = document.createElement("input");
	field.id = "yap-keyboard";
	field.type = "text";
	field.autocomplete = "off";
	field.setAttribute("autocorrect", "off");
	field.setAttribute("autocapitalize", "off");
	field.spellcheck = false;
	field.enterKeyHint = "send";
	// Out of sight but focusable. 16px, or iOS zooms the page to it.
	field.style.cssText =
		"position:fixed;left:0;top:0;width:1px;height:1px;opacity:0;border:0;padding:0;" +
		"font-size:16px;pointer-events:none;";
	document.body.appendChild(field);

	let last = KEEP;
	const reset = () => {
		field.value = KEEP;
		last = KEEP;
		field.setSelectionRange(KEEP.length, KEEP.length);
	};
	reset();

	const codepoints = (s) => Array.from(s);

	// Whatever the keyboard did - a letter, a backspace, a word swapped
	// for its correction - is the difference between the field before and
	// after, sent as backspaces and characters.
	field.addEventListener("input", (e) => {
		if (!ready()) return;
		const now = field.value;
		const before = codepoints(last.slice(KEEP.length));
		let after;
		let extra = 0;
		if (now.startsWith(KEEP)) {
			after = codepoints(now.slice(KEEP.length));
		} else {
			// The kept character went: a backspace with nothing typed.
			after = [];
			extra = 1;
		}
		let same = 0;
		while (same < before.length && same < after.length && before[same] === after[same]) same++;
		for (let i = 0; i < before.length - same + extra; i++) Module._web_text_backspace();
		for (const ch of after.slice(same)) Module._web_text_rune(ch.codePointAt(0));
		last = now;
		if (!now.startsWith(KEEP) || (!e.isComposing && now.length > TIDY_AT)) reset();
	});
	field.addEventListener("compositionend", () => {
		if (field.value.length > TIDY_AT) reset();
	});
	field.addEventListener("focus", reset);

	// Keys typed into the field are the field's: GLFW listens on the
	// whole window and would type them a second time. Enter is the one
	// the field doesn't turn into an edit.
	for (const type of ["keydown", "keypress", "keyup"]) {
		window.addEventListener(
			type,
			(e) => {
				if (e.target !== field) return;
				e.stopImmediatePropagation();
				if (type === "keydown" && e.key === "Enter") {
					e.preventDefault();
					if (ready()) Module._web_text_enter();
				}
			},
			true,
		);
	}

	// ---- touch ----

	let finger = null; // {id, x0, y0, x, y, mode: "tap" | "scroll" | "drag"}

	const own = (e) => {
		// Ours alone: no emulated mouse, no GLFW, no page scrolling.
		e.preventDefault();
		e.stopImmediatePropagation();
	};
	const find = (list) => {
		for (const t of list) if (finger && t.identifier === finger.id) return t;
		return null;
	};

	canvas.addEventListener(
		"touchstart",
		(e) => {
			own(e);
			if (finger) return; // one finger at a time
			const t = e.changedTouches[0];
			const [x, y] = where(t);
			finger = { id: t.identifier, x0: x, y0: y, x, y, mode: "tap" };
		},
		{ capture: true, passive: false },
	);

	canvas.addEventListener(
		"touchmove",
		(e) => {
			own(e);
			const t = find(e.changedTouches);
			if (!t || !ready()) return;
			const [x, y] = where(t);
			if (finger.mode === "tap") {
				const dx = x - finger.x0;
				const dy = y - finger.y0;
				if (Math.hypot(dx, dy) < SLOP) return;
				finger.mode = Math.abs(dy) >= Math.abs(dx) ? "scroll" : "drag";
				if (finger.mode === "drag") Module._web_touch_drag_begin(finger.x0, finger.y0);
			}
			if (finger.mode === "scroll") {
				Module._web_touch_scroll(x, y, finger.y - y);
			} else {
				Module._web_touch_drag_move(x, y);
			}
			finger.x = x;
			finger.y = y;
		},
		{ capture: true, passive: false },
	);

	const lift = (e, cancelled) => {
		own(e);
		const t = find(e.changedTouches);
		if (!t) return;
		const done = finger;
		finger = null;
		if (!ready()) return;
		if (done.mode === "drag") {
			Module._web_touch_drag_end();
		} else if (done.mode === "tap" && !cancelled) {
			const [x, y] = where(t);
			// Still inside the tap, where a phone allows the keyboard up.
			if (Module._web_text_box_at(x, y)) {
				field.focus({ preventScroll: true });
			} else if (document.activeElement === field) {
				field.blur();
			}
			Module._web_touch_tap(x, y);
		}
	};
	canvas.addEventListener("touchend", (e) => lift(e, false), { capture: true, passive: false });
	canvas.addEventListener("touchcancel", (e) => lift(e, true), { capture: true, passive: false });
})();
