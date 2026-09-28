#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(getconf DARWIN_USER_TEMP_DIR)/PulseBar-build"
APP_DIR="${1:-$PROJECT_DIR/../PulseBar.app}"
SDK_DIR="$(xcrun --show-sdk-path)"
mkdir -p "$BUILD_DIR/module-cache" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
xcrun clang -O2 -target arm64-apple-macos13.0 -isysroot "$SDK_DIR" -Wall -Wextra -Werror \
    -c "$PROJECT_DIR/Sources/Hardware.c" -o "$BUILD_DIR/Hardware.o"
xcrun clang -O2 -fobjc-arc -target arm64-apple-macos13.0 -isysroot "$SDK_DIR" -Wall -Wextra -Werror \
    -c "$PROJECT_DIR/Sources/TouchBarBridge.m" -o "$BUILD_DIR/TouchBarBridge.o"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos13.0 -sdk "$SDK_DIR" \
    -module-cache-path "$BUILD_DIR/module-cache" \
    -import-objc-header "$PROJECT_DIR/Sources/Bridging.h" \
    -framework AppKit -framework SwiftUI -framework IOKit -framework CoreLocation -framework ServiceManagement \
    "$PROJECT_DIR"/Sources/*.swift "$BUILD_DIR/Hardware.o" "$BUILD_DIR/TouchBarBridge.o" \
    -o "$APP_DIR/Contents/MacOS/PulseBar"
cp "$PROJECT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
cp "$PROJECT_DIR/Resources/codex-logo.png" "$APP_DIR/Contents/Resources/codex-logo.png"
cp "$PROJECT_DIR/ThirdParty/QuotaStrip-LICENSE.txt" "$APP_DIR/Contents/Resources/QuotaStrip-LICENSE.txt"
codesign --force --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
printf 'Built: %s\n' "$APP_DIR"
