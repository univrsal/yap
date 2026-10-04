// The composer's markdown keys (src/client/ui.odin, key_callback) are
// the browser's too: Ctrl+B bookmarks, Ctrl+I page info, Ctrl+U the
// page's source, Ctrl+E the search bar. On the page they're the client's:
// the browser's default is held back, and GLFW still gets the key. The
// page's own fields (the phone keyboard's, web/touch.js) are left alone.
(() => {
	window.addEventListener(
		"keydown",
		(e) => {
			if (!e.ctrlKey || e.altKey || e.metaKey) return;
			if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) return;
			const k = e.key.toLowerCase();
			if ((!e.shiftKey && "biue".includes(k) && k.length === 1) || (e.shiftKey && k === "x")) e.preventDefault();
		},
		true,
	);
})();
