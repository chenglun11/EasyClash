#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release -Xswiftc -debug-prefix-map -Xswiftc "$PWD=/EasyClash" -Xcc "-ffile-prefix-map=$PWD=/EasyClash"
BIN="$(swift build -c release --show-bin-path)"
APP="${EASYCLASH_APP_OUTPUT:-$PWD/dist/EasyClash.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/EasyClash" "$APP/Contents/MacOS/EasyClash"
cp "$BIN/EasyClashRecovery" "$APP/Contents/Helpers/EasyClashRecovery"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>EasyClash</string>
<key>CFBundleDisplayName</key><string>EasyClash</string>
<key>CFBundleIdentifier</key><string>com.easyclash.app</string>
<key>CFBundleExecutable</key><string>EasyClash</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 EasyClash contributors</string>
</dict></plist>
PLIST
if [[ -f "$APP/Contents/Resources/Yams-LICENSE.txt" ]]; then chmod u+w "$APP/Contents/Resources/Yams-LICENSE.txt"; fi
cp .build/checkouts/Yams/LICENSE "$APP/Contents/Resources/Yams-LICENSE.txt"
chmod 644 "$APP/Contents/Resources/Yams-LICENSE.txt"
# Remove linker debug-map entries containing absolute local object-file paths.
/usr/bin/strip -S "$APP/Contents/MacOS/EasyClash" "$APP/Contents/Helpers/EasyClashRecovery"
codesign --force --sign - "$APP/Contents/Helpers/EasyClashRecovery"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built: $APP (ad-hoc signed; not notarized)"
