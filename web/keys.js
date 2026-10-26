// Some of the client's keys (src/client/ui_window.odin, key_callback) are
// the browser's too. The composer's markdown keys: Ctrl+B bookmarks, Ctrl+I
// page info, Ctrl+U the page's source, Ctrl+E the search bar. The command
// palette's: Ctrl+K and Cmd+K the search bar. F6 the address bar. On the page
// they're the client's: the browser's default is held back, and GLFW still
// gets the key. The page's own fields (the phone keyboard's, web/touch.js) are
// left alone; web/field.js hands these keys on from its fields.
(() => {
	window.yapAppKey = (e) => {
		if (e.key === "F6") return !e.ctrlKey && !e.altKey && !e.metaKey;
		const k = e.key.toLowerCase();
		// Cmd+K, as on a Mac.
		if (e.metaKey) return !e.ctrlKey && !e.altKey && !e.shiftKey && k === "k";
		if (!e.ctrlKey || e.altKey) return false;
		if (!e.shiftKey && (k === " " || k === "k")) return true;
		return (!e.shiftKey && "biue".includes(k) && k.length === 1) || (e.shiftKey && k === "x");
	};
	window.addEventListener(
		"keydown",
		(e) => {
			if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) return;
			if (window.yapAppKey(e)) e.preventDefault();
		},
		true,
	);
})();
