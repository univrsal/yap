#+build !wasi
package client

import log "../common/wlog"
import "core:fmt"
import "core:os"
import "core:strings"
import mu "vendor:microui"

/*
Installing yap for the current user, from the settings page: whatever
the desktop needs to list it with the other programs, pointing at the
binary that's running, so a downloaded yap can be started like any
other program without moving it anywhere. Uninstalling removes it again
and leaves the binary alone.

What that is depends on the platform (install_<os>.odin):

- Linux and the BSDs: a .desktop entry and its icon under
  $XDG_DATA_HOME (~/.local/share), and a link in ~/.local/bin.
- macOS: ~/Applications/Yap.app, a bundle whose executable is a link.
- Windows: a Start menu shortcut.

Each platform provides:

	INSTALL_DESCRIPTION :: string
	install_query :: proc(allocator) -> (target: string, installed: bool)
	install_self :: proc(exe: string) -> (err: string)
	uninstall_self :: proc() -> (err: string)

install_query says which binary the installed entry starts (empty if it
can't tell), so a yap run from somewhere else can point it at itself.
*/

UI_Install :: struct {
	// Read when the settings page is opened (open_settings) and after
	// installing or uninstalling, not every frame.
	loaded:    bool,
	installed: bool,
	target:    string,
	exe:       string,
	error:     string,
}

install_destroy :: proc(ui: ^UI) {
	st := &ui.install
	delete(st.target)
	delete(st.exe)
	delete(st.error)
	st^ = {}
}

@(private = "file")
install_load :: proc(ui: ^UI) {
	st := &ui.install
	delete(st.target)
	delete(st.exe)
	st.exe, _ = os.get_executable_path(context.allocator)
	st.target, st.installed = install_query(context.allocator)
	st.loaded = true
}

@(private = "file")
install_do :: proc(ui: ^UI, install: bool) {
	st := &ui.install
	delete(st.error)
	st.error = ""
	err: string
	if install {
		if st.exe == "" {
			err = "Could not find out where this program is."
		} else {
			err = install_self(st.exe)
		}
	} else {
		err = uninstall_self()
	}
	if err != "" {
		log.errorf("%s: %s", "install" if install else "uninstall", err)
		st.error = err
	} else {
		log.infof("%s", "installed" if install else "uninstalled")
	}
	st.loaded = false
}

// install_settings is the settings page's section for it.
install_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	if !header(ctx, "Install") {
		return
	}
	st := &ui.install
	if !st.loaded {
		install_load(ui)
	}

	mu.layout_row(ctx, {-1})
	mu.text(ctx, INSTALL_DESCRIPTION)

	// Windows paths don't care about case.
	same := strings.equal_fold(st.target, st.exe) if ODIN_OS == .Windows else st.target == st.exe
	elsewhere := st.installed && st.target != "" && st.exe != "" && !same
	mu.layout_row(ctx, {-(2 * (110 + ctx.style.spacing)), 110, 110})
	switch {
	case !st.installed:
		with_text_color(ctx, DIM_COLOR, "  Not installed.", label_proc)
	case elsewhere:
		with_text_color(ctx, WARNING_COLOR, fmt.tprintf("  Installed, but starts %s", st.target), label_proc)
	case:
		mu.label(ctx, "  Installed.")
	}
	if !st.installed {
		if .SUBMIT in mu.button(ctx, "Install") {
			install_do(ui, true)
		}
	} else if elsewhere {
		if .SUBMIT in mu.button(ctx, "Use this copy") {
			install_do(ui, true)
		}
	} else {
		// Keeps the Uninstall button in the same place either way.
		mu.label(ctx, "")
	}
	if st.installed {
		if .SUBMIT in mu.button(ctx, "Uninstall") {
			install_do(ui, false)
		}
	}
	if st.error != "" {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, ERROR_COLOR, st.error, label_proc)
	}
}
