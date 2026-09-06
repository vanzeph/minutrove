#!/usr/bin/env bash
set -euo pipefail
CHIME_SIMULATOR_ID=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(x["udid"] for key,items in d["devices"].items() if "iOS" in key for x in items if x["name"].startswith("iPhone")))')
xcrun simctl boot "$CHIME_SIMULATOR_ID" || true
xcrun simctl bootstatus "$CHIME_SIMULATOR_ID" -b
xcodebuild test -project ios/Runner.xcodeproj -scheme Runner \
  -destination "platform=iOS Simulator,id=$CHIME_SIMULATOR_ID" \
  -only-testing:RunnerTests/RunnerTests -parallel-testing-enabled NO \
  -destination-timeout 120 -test-timeouts-enabled YES \
  -maximum-test-execution-time-allowance 30 CODE_SIGNING_ALLOWED=NO
