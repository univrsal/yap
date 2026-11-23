#+build !wasi
package client

import "client:settings"
import log "common:wlog"
import "core:fmt"
import "core:os"
import "core:strings"
import mu "vendor:microui"

// Installs yap for the current user from the settings page. This creates
// whatever the desktop needs to list yap among the other programs, pointing at
// the binary that is running, so a downloaded yap can be started like any other
// program without moving it anywhere. Uninstalling removes this again and
// leaves the binary alone.
//
// What gets installed depends on the platform (settings/install_<os>.odin):
//
// - Linux and the BSDs: a .desktop entry and its icon under
//   $XDG_DATA_HOME (~/.local/share), and a link in ~/.local/bin.
// - macOS: ~/Applications/Yap.app, a bundle whose executable is a link.
// - Windows: a Start menu shortcut.
//
// Each platform provides:
//
//	INSTALL_DESCRIPTION :: string
//	install_query :: proc(allocator) -> (target: string, installed: bool)
//	install_self :: proc(exe: string, icon_png: []u8) -> (err: string)
//	uninstall_self :: proc() -> (err: string)
//	autostart_query :: proc(allocator) -> (target: string, on: bool)
//	autostart_set :: proc(exe: string, on: bool) -> (err: string)
//
// Starting at login (autostart_*) doesn't need yap to be installed: the entry
// starts the binary that is running when it is switched on.
//
// install_query returns the binary that the installed entry starts (empty if
// it can't tell), so that a yap run from somewhere else can point the entry at
// itself. icon_png is the icon to install along with it, on platforms where
// the entry has its own icon (Linux, the BSDs and macOS).

UI_Install :: struct {
	// Read when the settings page is opened (open_settings) and after
	// installing or uninstalling, not every frame.
	loaded:           bool,
	installed:        bool,
	// Whether yap starts when the user logs in, and the binary that it starts.
	autostart:        bool,
	autostart_target: string,
	target:           string,
	exe:              string,
	error:            string,
}

install_destroy :: proc(ui: ^UI) {
	st := &ui.install
	delete(st.target)
	delete(st.exe)
	delete(st.error)
	delete(st.autostart_target)
	st^ = {}
}

@(private = "file")
install_load :: proc(ui: ^UI) {
	st := &ui.install
	delete(st.target)
	delete(st.exe)
	st.exe, _ = os.get_executable_path(context.allocator)
	st.target, st.installed = settings.install_query(context.allocator)
	delete(st.autostart_target)
	st.autostart_target, st.autostart = settings.autostart_query(context.allocator)
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
			err = "Could not determine the location of this program's executable."
		} else {
			err = settings.install_self(st.exe, ICON_PNG)
		}
	} else {
		err = settings.uninstall_self()
	}
	if err != "" {
		log.errorf("%s: %s", "install" if install else "uninstall", err)
		st.error = err
	} else {
		log.infof("%s", "installed" if install else "uninstalled")
	}
	st.loaded = false
}

// autostart_do switches starting at login on or off.
@(private = "file")
autostart_do :: proc(ui: ^UI, on: bool) {
	st := &ui.install
	delete(st.error)
	st.error = ""
	err: string
	if on && st.exe == "" {
		err = "Could not determine the location of this program's executable."
	} else {
		err = settings.autostart_set(st.exe, on)
	}
	if err != "" {
		log.errorf("autostart: %s", err)
		st.error = strings.clone(err)
	} else {
		log.infof("autostart %s", "on" if on else "off")
	}
	st.loaded = false
}

// install_settings draws the installation section of the settings page.
install_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	st := &ui.install
	if !st.loaded {
		install_load(ui)
	}

	mu.layout_row(ctx, {-1})
	wrap_text(ctx, settings.INSTALL_DESCRIPTION)

	// Windows paths are case-insensitive.
	same := strings.equal_fold(st.target, st.exe) if ODIN_OS == .Windows else st.target == st.exe
	elsewhere := st.installed && st.target != "" && st.exe != "" && !same
	mu.layout_row(ctx, {-(2 * (110 + ctx.style.spacing)), 109, 109})
	switch {
	case !st.installed:
		dim_label(ctx, "  Not installed.")
	case elsewhere:
		with_text_color(
			ctx,
			theme.warning,
			fmt.tprintf("  Installed, but points to %s", st.target),
			label_proc,
		)
	case:
		mu.label(ctx, "  Installed.")
	}
	if !st.installed {
		if .SUBMIT in button(ctx, "Install") {
			install_do(ui, true)
		}
	} else if elsewhere {
		if .SUBMIT in button(ctx, "Use this copy") {
			install_do(ui, true)
		}
	} else {
		// An empty cell keeps the Uninstall button in the same place.
		mu.label(ctx, "")
	}
	if st.installed {
		if .SUBMIT in button(ctx, "Uninstall") {
			install_do(ui, false)
		}
	}

	// Starting at login, which works with or without the installation.
	mu.layout_row(ctx, {-1})
	on := st.autostart
	if .CHANGE in checkbox(ctx, "Start yap when I log in", &on) {
		autostart_do(ui, on)
	}
	autostart_same :=
		strings.equal_fold(st.autostart_target, st.exe) if ODIN_OS == .Windows else st.autostart_target == st.exe
	if st.autostart && st.autostart_target != "" && st.exe != "" && !autostart_same {
		mu.layout_row(ctx, {-1})
		with_text_color(
			ctx,
			theme.warning,
			fmt.tprintf(
				"  It starts %s; switch it off and on to start this copy.",
				st.autostart_target,
			),
			label_proc,
		)
	}
	if st.error != "" {
		mu.layout_row(ctx, {-1})
		error_label(ctx, st.error)
	}
}
