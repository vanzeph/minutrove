#!/usr/bin/env bash
# Drive the same Dart suite through Flutter's native XCTest bridge.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tool/verify_toolchain.py
flutter pub get --enforce-lockfile
flutter build ios --simulator --debug --config-only --target integration_test/app_test.dart \
  --dart-define=MINUTROVE_NATIVE_XCTEST=true
output="$PWD/build/ios-integration"
xcodebuild build-for-testing -project ios/Runner.xcodeproj -scheme Runner \
  -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$output" CODE_SIGNING_ALLOWED=NO 'OTHER_LDFLAGS=$(inherited) -ObjC'
device=$(xcrun simctl create Minutrove-Integration com.apple.CoreSimulator.SimDeviceType.iPhone-16 com.apple.CoreSimulator.SimRuntime.iOS-18-5)
trap 'xcrun simctl shutdown "$device"; xcrun simctl delete "$device"' EXIT
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
xcodebuild test-without-building -project ios/Runner.xcodeproj -scheme Runner \
  -configuration Debug -derivedDataPath "$output" \
  -destination "platform=iOS Simulator,id=$device" \
  -only-testing:RunnerTests/IntegrationTests -parallel-testing-enabled NO \
  -destination-timeout 120 -test-timeouts-enabled YES \
  -maximum-test-execution-time-allowance 120 CODE_SIGNING_ALLOWED=NO
