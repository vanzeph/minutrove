#!/usr/bin/env bash
set -euo pipefail
# Headless, synthetic instrumented tests; no signing or public artifact upload.
SDK_ROOT="${ANDROID_HOME:?Android SDK is required}"
printf 'y\n' | "$SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" 'system-images;android-29;google_apis;x86_64' >/dev/null
printf 'no\n' | "$SDK_ROOT/cmdline-tools/latest/bin/avdmanager" create avd --force --name chime --package 'system-images;android-29;google_apis;x86_64'
"$SDK_ROOT/emulator/emulator" -avd chime -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect > /tmp/chime-emulator.log 2>&1 &
CHIME_EMULATOR_PID=$!
trap 'kill "$CHIME_EMULATOR_PID" || true' EXIT
"$SDK_ROOT/platform-tools/adb" wait-for-device
for attempt in $(seq 1 120); do
  if [[ "$("$SDK_ROOT/platform-tools/adb" shell getprop sys.boot_completed | tr -d '\r')" == 1 ]]; then break; fi
  sleep 2
done
"$SDK_ROOT/platform-tools/adb" shell getprop ro.build.version.release
(cd android && ./gradlew app:connectedDebugAndroidTest)
