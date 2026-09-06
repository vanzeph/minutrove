#!/usr/bin/env bash
set -euo pipefail
# Headless, synthetic instrumented tests; no signing or public artifact upload.
SDK_ROOT="${ANDROID_HOME:?Android SDK is required}"
# Recent SDK tools and emulator releases may choose different default homes.
# Use the same explicit AVD registry and image directory for both processes.
export ANDROID_AVD_HOME="${RUNNER_TEMP:-/tmp}/minutrove-chime-avd"
mkdir -p "$ANDROID_AVD_HOME"
printf 'y\n' | "$SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" 'system-images;android-29;google_apis;x86_64' >/dev/null
printf 'no\n' | "$SDK_ROOT/cmdline-tools/latest/bin/avdmanager" create avd --force --name chime --path "$ANDROID_AVD_HOME/chime.avd" --package 'system-images;android-29;google_apis;x86_64'
"$SDK_ROOT/emulator/emulator" -list-avds
"$SDK_ROOT/emulator/emulator" -avd chime -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect > /tmp/chime-emulator.log 2>&1 &
CHIME_EMULATOR_PID=$!
trap 'tail -100 /tmp/chime-emulator.log; kill "$CHIME_EMULATOR_PID" 2>/dev/null || true' EXIT
for attempt in $(seq 1 60); do
  kill -0 "$CHIME_EMULATOR_PID" || { echo 'Emulator exited before connecting'; exit 1; }
  if "$SDK_ROOT/platform-tools/adb" get-state 2>/dev/null | grep -q '^device$'; then break; fi
  sleep 2
done
"$SDK_ROOT/platform-tools/adb" get-state
for attempt in $(seq 1 120); do
  if [[ "$("$SDK_ROOT/platform-tools/adb" shell getprop sys.boot_completed | tr -d '\r')" == 1 ]]; then break; fi
  sleep 2
done
[[ "$("$SDK_ROOT/platform-tools/adb" shell getprop sys.boot_completed | tr -d '\r')" == 1 ]] || { echo 'Emulator boot timed out'; exit 1; }
"$SDK_ROOT/platform-tools/adb" shell getprop ro.build.version.release
(cd android && ./gradlew app:connectedDebugAndroidTest)
