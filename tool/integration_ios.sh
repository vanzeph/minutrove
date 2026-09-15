#!/usr/bin/env bash
# Drive the same Dart suite through Flutter's native XCTest bridge, then run
# the native RunnerTests suite on the same simulator. MINUTROVE_IOS_RUNTIME and
# MINUTROVE_IOS_DEVICETYPE broaden the verified OS/device matrix without
# changing the pinned default destination.
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
runtime="${MINUTROVE_IOS_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-18-5}"
devicetype="${MINUTROVE_IOS_DEVICETYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-16}"
device=$(xcrun simctl create Minutrove-Integration "$devicetype" "$runtime")
trap 'xcrun simctl shutdown "$device"; xcrun simctl delete "$device"' EXIT
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
# The whole Dart integration suite runs inside one XCTest case, so the
# execution allowance must bound the full suite, not one Dart test. The
# product journeys alone need ~3.5 minutes on the simulator; 600 seconds
# still fails fast on a genuine hang while staying inside the job's
# 20-minute step timeout.
xcodebuild test-without-building -project ios/Runner.xcodeproj -scheme Runner \
  -configuration Debug -derivedDataPath "$output" \
  -destination "platform=iOS Simulator,id=$device" \
  -only-testing:RunnerTests/IntegrationTests -parallel-testing-enabled NO \
  -destination-timeout 120 -test-timeouts-enabled YES \
  -maximum-test-execution-time-allowance 600 CODE_SIGNING_ALLOWED=NO
# The native notification, durable-clock and chime suite runs on the same
# booted device so every OS in the matrix observes the real
# UserNotifications center and audio behavior, not only the pinned build leg.
xcodebuild test-without-building -project ios/Runner.xcodeproj -scheme Runner \
  -configuration Debug -derivedDataPath "$output" \
  -destination "platform=iOS Simulator,id=$device" \
  -only-testing:RunnerTests/RunnerTests -parallel-testing-enabled NO \
  -destination-timeout 120 -test-timeouts-enabled YES \
  -maximum-test-execution-time-allowance 60 CODE_SIGNING_ALLOWED=NO
