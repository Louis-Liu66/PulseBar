#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="${PULSEBAR_LAYOUT_WORK_DIR:-$PROJECT_DIR/../../work/pulsebar-v2}"
BUILD_DIR="$WORK_DIR/layout-tests"
APP_DIR="$BUILD_DIR/PulseBarLayoutTests.app"
SDK_DIR="$(xcrun --show-sdk-path)"
mkdir -p "$BUILD_DIR/module-cache" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$WORK_DIR/previews"
xcrun clang -O2 -target arm64-apple-macos13.0 -isysroot "$SDK_DIR" -Wall -Wextra -Werror \
    -c "$PROJECT_DIR/Sources/Hardware.c" -o "$BUILD_DIR/Hardware.o"
xcrun clang -O2 -fobjc-arc -target arm64-apple-macos13.0 -isysroot "$SDK_DIR" -Wall -Wextra -Werror \
    -c "$PROJECT_DIR/Sources/TouchBarBridge.m" -o "$BUILD_DIR/TouchBarBridge.o"
SWIFT_SOURCES=()
for source in "$PROJECT_DIR"/Sources/*.swift; do
    if [[ "$(basename "$source")" != Main.swift ]]; then SWIFT_SOURCES+=("$source"); fi
done
xcrun swiftc -swift-version 5 -target arm64-apple-macos13.0 -sdk "$SDK_DIR" \
    -module-cache-path "$BUILD_DIR/module-cache" -import-objc-header "$PROJECT_DIR/Sources/Bridging.h" \
    -framework AppKit -framework SwiftUI -framework IOKit -framework CoreLocation -framework ServiceManagement \
    "${SWIFT_SOURCES[@]}" "$PROJECT_DIR/Tests/TouchBarLayoutTests.swift" \
    "$BUILD_DIR/Hardware.o" "$BUILD_DIR/TouchBarBridge.o" -o "$APP_DIR/Contents/MacOS/PulseBarLayoutTests"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.pulsebar.layout-tests</string>
<key>CFBundleExecutable</key><string>PulseBarLayoutTests</string>
<key>CFBundleName</key><string>PulseBar Fixture Layout Tests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
cp "$PROJECT_DIR/Resources/codex-logo.png" "$APP_DIR/Contents/Resources/codex-logo.png"
"$APP_DIR/Contents/MacOS/PulseBarLayoutTests" "$WORK_DIR/previews"
