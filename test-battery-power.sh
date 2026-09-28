#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${PULSEBAR_BATTERY_POWER_WORK_DIR:-$(getconf DARWIN_USER_TEMP_DIR)/PulseBar-battery-power-tests}"
mkdir -p "$BUILD_DIR/module-cache"
xcrun clang -O2 -target arm64-apple-macos13.0 -Wall -Wextra -Werror \
    -framework IOKit -framework CoreFoundation "$PROJECT_DIR/Tests/BatteryElectricalTests.c" \
    -o "$BUILD_DIR/BatteryElectricalTests"
"$BUILD_DIR/BatteryElectricalTests"
xcrun clang -O2 -target arm64-apple-macos13.0 -Wall -Wextra -Werror \
    -c "$PROJECT_DIR/Sources/Hardware.c" -o "$BUILD_DIR/Hardware.o"
xcrun swiftc -swift-version 5 -target arm64-apple-macos13.0 -warnings-as-errors \
    -module-cache-path "$BUILD_DIR/module-cache" -import-objc-header "$PROJECT_DIR/Sources/Hardware.h" \
    -framework IOKit "$PROJECT_DIR/Sources/MetricPresentation.swift" \
    "$PROJECT_DIR/Sources/SystemMetrics.swift" "$PROJECT_DIR/Sources/BatteryEstimate.swift" \
    "$PROJECT_DIR/Tests/BatteryPowerTests.swift" \
    "$BUILD_DIR/Hardware.o" -o "$BUILD_DIR/BatteryPowerTests"
"$BUILD_DIR/BatteryPowerTests" "$@"
