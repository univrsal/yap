package settings

import "core:os"
import "core:strings"

// Starting yap when the user logs in (the client's ui_install_native.odin has
// the checkbox) is a launch agent on macOS: a property list in
// ~/Library/LaunchAgents that launchd reads at login and that asks for the
// program to be run then (RunAtLoad). It starts the binary that is running when
// it is switched on, so yap does not need to be installed.

@(private = "file")
AUTOSTART_LABEL :: "com.github.univrsal.yap"

@(private = "file")
autostart_path :: proc() -> (path: string, ok: bool) {
	home, err := os.user_home_dir(context.temp_allocator)
	if err != nil {
		return
	}
	path, _ = os.join_path(
		{home, "Library", "LaunchAgents", AUTOSTART_LABEL + ".plist"},
		context.temp_allocator,
	)
	return path, true
}

// xml_escape escapes text for an element of a property list.
@(private = "file")
xml_escape :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "&", "&amp;", context.temp_allocator)
	out, _ = strings.replace_all(out, "<", "&lt;", context.temp_allocator)
	out, _ = strings.replace_all(out, ">", "&gt;", context.temp_allocator)
	return out
}

@(private = "file")
xml_unescape :: proc(s: string, allocator := context.allocator) -> string {
	out, _ := strings.replace_all(s, "&lt;", "<", context.temp_allocator)
	out, _ = strings.replace_all(out, "&gt;", ">", context.temp_allocator)
	out, _ = strings.replace_all(out, "&amp;", "&", allocator)
	return out
}

// autostart_query returns whether yap starts at login, and the binary that it
// starts ("" if it can't tell).
autostart_query :: proc(allocator := context.allocator) -> (target: string, on: bool) {
	path := autostart_path() or_return
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return
	}
	text := string(data)
	// The first string after the key ProgramArguments.
	if i := strings.index(text, "<key>ProgramArguments</key>"); i >= 0 {
		rest := text[i:]
		if a := strings.index(rest, "<string>"); a >= 0 {
			rest = rest[a + len("<string>"):]
			if b := strings.index(rest, "</string>"); b >= 0 {
				target = xml_unescape(rest[:b], allocator)
			}
		}
	}
	return target, true
}

// autostart_set makes yap start at login, or not.
autostart_set :: proc(exe: string, on: bool) -> (err: string) {
	path, ok := autostart_path()
	if !ok {
		return "Could not find your home folder."
	}
	if !on {
		if os.exists(path) && os.remove(path) != nil {
			return strings.concatenate({"Could not remove ", path}, context.temp_allocator)
		}
		return ""
	}
	plist := strings.concatenate(
		{
			`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>` +
			AUTOSTART_LABEL +
			`</string>
	<key>ProgramArguments</key>
	<array>
		<string>`,
			xml_escape(exe),
			`</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
</dict>
</plist>
`,
		},
		context.temp_allocator,
	)
	dir, _ := os.split_path(path)
	os.make_directory_all(dir)
	if os.write_entire_file(path, plist) != nil {
		return strings.concatenate({"Could not write ", path}, context.temp_allocator)
	}
	return ""
}
