package client

import "core:encoding/endian"
import "core:os"
import "core:strings"

/*
Installing on macOS (see ui_install_native.odin): a bundle,
~/Applications/Yap.app, which Finder, Launchpad and Spotlight list with
the other apps. Its executable is a link to the binary rather than a
copy, and its icon is assets/icon.png wrapped as an .icns.

Started from the bundle, macOS asks for the microphone on the app's
behalf (NSMicrophoneUsageDescription) instead of on the terminal's.
*/

INSTALL_DESCRIPTION :: "Adds Yap.app to the Applications folder in your home folder, so it can be started from Finder, Launchpad or Spotlight. The app starts this copy of yap; nothing is copied or moved. Uninstall removes it again."

@(private = "file")
INFO_PLIST :: `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>yap</string>
	<key>CFBundleIdentifier</key>
	<string>com.github.univrsal.yap</string>
	<key>CFBundleName</key>
	<string>Yap</string>
	<key>CFBundleIconFile</key>
	<string>yap</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>Yap sends your microphone to the voice channel you join.</string>
</dict>
</plist>
`

@(private = "file")
Install_Paths :: struct {
	bundle, contents, macos, resources, exe, plist, icon: string,
}

// install_paths are the bundle's files; all in the temp allocator.
@(private = "file")
install_paths :: proc() -> (p: Install_Paths, ok: bool) {
	home, err := os.user_home_dir(context.temp_allocator)
	if err != nil {
		return
	}
	join :: proc(parts: ..string) -> string {
		s, _ := os.join_path(parts, context.temp_allocator)
		return s
	}
	p.bundle = join(home, "Applications", "Yap.app")
	p.contents = join(p.bundle, "Contents")
	p.macos = join(p.contents, "MacOS")
	p.resources = join(p.contents, "Resources")
	p.exe = join(p.macos, "yap")
	p.plist = join(p.contents, "Info.plist")
	p.icon = join(p.resources, "yap.icns")
	return p, true
}

install_query :: proc(allocator := context.allocator) -> (target: string, installed: bool) {
	p := install_paths() or_return
	if !os.exists(p.plist) {
		return
	}
	target, _ = os.read_link(p.exe, allocator)
	return target, true
}

install_self :: proc(exe: string) -> (err: string) {
	p, ok := install_paths()
	if !ok {
		return "Could not find your home folder."
	}
	os.make_directory_all(p.macos)
	os.make_directory_all(p.resources)
	if os.write_entire_file(p.plist, INFO_PLIST) != nil {
		return strings.concatenate({"Could not write ", p.plist}, context.temp_allocator)
	}
	if os.write_entire_file(p.icon, icns_from_png(ICON_PNG)) != nil {
		return strings.concatenate({"Could not write ", p.icon}, context.temp_allocator)
	}
	os.remove(p.exe)
	if os.symlink(exe, p.exe) != nil {
		return strings.concatenate({"Could not make the link ", p.exe}, context.temp_allocator)
	}
	return ""
}

// uninstall_self removes the files it put there, one by one, so
// anything else that ended up in the bundle keeps it from going.
uninstall_self :: proc() -> (err: string) {
	p, ok := install_paths()
	if !ok {
		return "Could not find your home folder."
	}
	for path in ([]string{p.exe, p.icon, p.plist, p.macos, p.resources, p.contents}) {
		os.remove(path)
	}
	if os.exists(p.bundle) && os.remove(p.bundle) != nil {
		return strings.concatenate({"Could not remove ", p.bundle}, context.temp_allocator)
	}
	return ""
}

/*
icns_from_png wraps a 128x128 PNG as an .icns: the "icns" header and one
"ic07" (128x128) entry, which may hold a PNG as it is. Each has its
length, header included, as a big-endian u32.
*/
@(private = "file")
icns_from_png :: proc(png: []u8) -> []u8 {
	out := make([]u8, 16 + len(png), context.temp_allocator)
	copy(out[0:], "icns")
	endian.put_u32(out[4:8], .Big, u32(len(out)))
	copy(out[8:], "ic07")
	endian.put_u32(out[12:16], .Big, u32(8 + len(png)))
	copy(out[16:], png)
	return out
}
