#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="${PULSEBAR_LAYOUT_WORK_DIR:-$PROJECT_DIR/../../work/pulsebar-v2}"
BUILD_DIR="$WORK_DIR/transition-tests"
SDK_DIR="$(xcrun --show-sdk-path)"
mkdir -p "$BUILD_DIR/module-cache"
xcrun swiftc -swift-version 5 -target arm64-apple-macos13.0 -sdk "$SDK_DIR" \
    -warnings-as-errors -D PULSEBAR_TRANSITION_STANDALONE \
    -module-cache-path "$BUILD_DIR/module-cache" -framework AppKit -framework QuartzCore \
    "$PROJECT_DIR/Sources/TouchBarTransitionView.swift" "$PROJECT_DIR/Tests/TransitionTests.swift" \
    -o "$BUILD_DIR/TransitionTests"
"$BUILD_DIR/TransitionTests"
