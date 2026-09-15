#!/usr/bin/env bash
set -euo pipefail
# Drive the Dart integration suite on a headless Android 13 (API 33) image,
# the same emulator baseline as the notification/chime checks. The suite
# exercises the app's real on-device SQLite through the platform sqflite
# channel; the cross-platform backup tests assert this platform exports and
# restores the pinned reference bytes.
SDK_ROOT="${ANDROID_HOME:?Android SDK is required}"
# Recent SDK tools and emulator releases may choose different default homes.
# Use the same explicit AVD registry and image directory for both processes.
export ANDROID_AVD_HOME="${RUNNER_TEMP:-/tmp}/minutrove-integration-avd"
mkdir -p "$ANDROID_AVD_HOME"
printf 'y\n' | "$SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" 'system-images;android-33;google_apis;x86_64' >/dev/null
printf 'no\n' | "$SDK_ROOT/cmdline-tools/latest/bin/avdmanager" create avd --force --name integration --path "$ANDROID_AVD_HOME/integration.avd" --package 'system-images;android-33;google_apis;x86_64'
"$SDK_ROOT/emulator/emulator" -list-avds
"$SDK_ROOT/emulator/emulator" -avd integration -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect > /tmp/integration-emulator.log 2>&1 &
INTEGRATION_EMULATOR_PID=$!
trap 'tail -100 /tmp/integration-emulator.log; kill "$INTEGRATION_EMULATOR_PID" 2>/dev/null || true' EXIT
for attempt in $(seq 1 60); do
  kill -0 "$INTEGRATION_EMULATOR_PID" || { echo 'Emulator exited before connecting'; exit 1; }
  if "$SDK_ROOT/platform-tools/adb" get-state 2>/dev/null | grep -q '^device$'; then break; fi
  sleep 2
done
"$SDK_ROOT/platform-tools/adb" get-state
for attempt in $(seq 1 120); do
  if [[ "$("$SDK_ROOT/platform-tools/adb" shell getprop sys.boot_completed | tr -d '\r')" == 1 ]]; then break; fi
  sleep 2
done
[[ "$("$SDK_ROOT/platform-tools/adb" shell getprop sys.boot_completed | tr -d '\r')" == 1 ]] || { echo 'Emulator boot timed out'; exit 1; }
# The suite needs no runtime permissions or unlocked storage; wake and
# dismiss best effort so the first frame is drawn promptly.
ADB="$SDK_ROOT/platform-tools/adb"
"$ADB" wait-for-device
"$ADB" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
"$ADB" shell wm dismiss-keyguard >/dev/null 2>&1 || true
"$ADB" shell getprop ro.build.version.release
device="$("$ADB" devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
[[ -n "$device" ]] || { echo 'No emulator device found'; exit 1; }
python3 tool/verify_toolchain.py
flutter pub get --enforce-lockfile
flutter test integration_test --reporter expanded -d "$device"
