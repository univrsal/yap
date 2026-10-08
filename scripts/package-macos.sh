#!/bin/sh
# Wraps the client in a macOS app bundle and a disk image (dist/Yap-<arch>.dmg)
# to drag into Applications. The server and the web build aren't included.
# Usage: scripts/package-macos.sh <arch>
# Run after build.sh on macOS. YAP_VERSION (e.g. v0.1.0) sets the bundle version.
set -e
cd "$(dirname "$0")/.."
arch=${1:?usage: package-macos.sh <arch>}

version=${YAP_VERSION#v}
version=${version:-0.0.0}

app=dist/Yap.app
rm -rf "$app" dist/dmg "dist/Yap-$arch.dmg"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp bin/yap "$app/Contents/MacOS/yap"

# The icon: an .icns made from the png at the sizes macOS asks for.
iconset=dist/yap.iconset
rm -rf "$iconset"
mkdir -p "$iconset"
for s in 16 32 128 256 512; do
	sips -z $s $s src/client/assets/icon.png --out "$iconset/icon_${s}x${s}.png" >/dev/null
	sips -z $((s * 2)) $((s * 2)) src/client/assets/icon.png --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/yap.icns"
rm -rf "$iconset"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>Yap</string>
	<key>CFBundleDisplayName</key><string>Yap</string>
	<key>CFBundleIdentifier</key><string>cc.vrsal.yap</string>
	<key>CFBundleExecutable</key><string>yap</string>
	<key>CFBundleIconFile</key><string>yap</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$version</string>
	<key>CFBundleVersion</key><string>$version</string>
	<key>LSMinimumSystemVersion</key><string>11.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSMicrophoneUsageDescription</key><string>Yap needs the microphone for voice chat.</string>
</dict>
</plist>
PLIST

# Ad-hoc signed: not notarized, but the bundle is at least internally consistent.
codesign --force --deep --sign - "$app"

mkdir -p dist/dmg
cp -R "$app" dist/dmg/
ln -s /Applications dist/dmg/Applications
hdiutil create -volname Yap -srcfolder dist/dmg -ov -format UDZO "dist/Yap-$arch.dmg" >/dev/null
rm -rf dist/dmg
echo "packed dist/Yap-$arch.dmg"
