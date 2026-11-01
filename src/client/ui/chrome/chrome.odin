// The window's own decorations, which need nothing from the UI: its icon, and
// asking Wayland for the compositor's title bars. (The UI's own title bar,
// which does need the UI, is ui/titlebar.odin.)
//
// The files are specific to a platform, so this one keeps the package from
// being empty on the others.
package chrome
