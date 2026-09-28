#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(getconf DARWIN_USER_TEMP_DIR)/PulseBar-tests"
mkdir -p "$BUILD_DIR/module-cache"
xcrun swiftc -swift-version 5 -target arm64-apple-macos13.0 -module-cache-path "$BUILD_DIR/module-cache" \
    -framework CoreLocation "$PROJECT_DIR/Sources/WeatherService.swift" \
    "$PROJECT_DIR/Tests/WeatherTests.swift" -o "$BUILD_DIR/WeatherTests"
"$BUILD_DIR/WeatherTests"
xcrun swiftc -swift-version 5 -target arm64-apple-macos13.0 -module-cache-path "$BUILD_DIR/module-cache" \
    -framework CoreLocation "$PROJECT_DIR/Sources/WeatherService.swift" \
    "$PROJECT_DIR/Sources/WeatherAdvice.swift" "$PROJECT_DIR/Tests/WeatherAdviceTests.swift" \
    -o "$BUILD_DIR/WeatherAdviceTests"
"$BUILD_DIR/WeatherAdviceTests"
xcrun swiftc -swift-version 5 -target arm64-apple-macos13.0 -module-cache-path "$BUILD_DIR/module-cache" \
    "$PROJECT_DIR/Sources/CodexUsageService.swift" "$PROJECT_DIR/Tests/CodexUsageTests.swift" \
    -o "$BUILD_DIR/CodexUsageTests"
"$BUILD_DIR/CodexUsageTests"

xcrun swiftc -swift-version 5 -target arm64-apple-macos13.0 -module-cache-path "$BUILD_DIR/module-cache" \
    "$PROJECT_DIR/Sources/MetricPresentation.swift" "$PROJECT_DIR/Tests/MetricPresentationTests.swift" \
    -o "$BUILD_DIR/MetricPresentationTests"
"$BUILD_DIR/MetricPresentationTests"
xcrun swiftc -swift-version 5 -target arm64-apple-macos13.0 -module-cache-path "$BUILD_DIR/module-cache" \
    -framework CoreLocation "$PROJECT_DIR/Sources/WeatherService.swift" \
    "$PROJECT_DIR/Tests/AutomaticWeatherTests.swift" -o "$BUILD_DIR/AutomaticWeatherTests"
"$BUILD_DIR/AutomaticWeatherTests"

xcrun clang -O2 -target arm64-apple-macos13.0 -Wall -Wextra -Werror \
    -c "$PROJECT_DIR/Sources/Hardware.c" -o "$BUILD_DIR/BatteryHardware.o"
xcrun swiftc -swift-version 5 -target arm64-apple-macos13.0 -module-cache-path "$BUILD_DIR/module-cache" \
    -import-objc-header "$PROJECT_DIR/Sources/Hardware.h" -framework IOKit \
    "$PROJECT_DIR/Sources/MetricPresentation.swift" "$PROJECT_DIR/Sources/SystemMetrics.swift" \
    "$PROJECT_DIR/Tests/BatteryTests.swift" "$BUILD_DIR/BatteryHardware.o" -o "$BUILD_DIR/BatteryTests"
"$BUILD_DIR/BatteryTests"

xcrun swiftc -swift-version 5 -target arm64-apple-macos13.0 -module-cache-path "$BUILD_DIR/module-cache" \
    -warnings-as-errors "$PROJECT_DIR/Sources/MetricPresentation.swift" \
    "$PROJECT_DIR/Sources/BatteryEstimate.swift" "$PROJECT_DIR/Tests/BatteryEstimateTests.swift" \
    -o "$BUILD_DIR/BatteryEstimateTests"
"$BUILD_DIR/BatteryEstimateTests"
"$PROJECT_DIR/test-battery-power.sh"
