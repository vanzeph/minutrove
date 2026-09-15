#!/usr/bin/env bash
set -euo pipefail
# Headless, synthetic instrumented tests on an Android 13 (API 33) image so
# runtime POST_NOTIFICATIONS denial is exercised; no signing or artifact upload.
SDK_ROOT="${ANDROID_HOME:?Android SDK is required}"
# Recent SDK tools and emulator releases may choose different default homes.
# Use the same explicit AVD registry and image directory for both processes.
export ANDROID_AVD_HOME="${RUNNER_TEMP:-/tmp}/minutrove-chime-avd"
mkdir -p "$ANDROID_AVD_HOME"
printf 'y\n' | "$SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" 'system-images;android-33;google_apis;x86_64' >/dev/null
printf 'no\n' | "$SDK_ROOT/cmdline-tools/latest/bin/avdmanager" create avd --force --name chime --path "$ANDROID_AVD_HOME/chime.avd" --package 'system-images;android-33;google_apis;x86_64'
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
# boot_completed alone can precede credential-encrypted storage availability;
# runtime permission grants and notification posts fail while user 0 is locked.
# Try every headless unlock technique, then wait for either the unlock
# property or the user manager reporting the running user as unlocked.
ADB="$SDK_ROOT/platform-tools/adb"
user_unlocked() {
  [[ "$("$ADB" shell getprop sys.user.0.unlock_completed | tr -d '\r')" == 1 ]] && return 0
  # Some images never set the unlock property; the user manager state is the
  # authoritative signal (e.g. "Started users state: [0=RUNNING_UNLOCKED]").
  "$ADB" shell dumpsys user 2>/dev/null | tr -d '\r' | \
    grep -Eq 'State: RUNNING_UNLOCKED|0=RUNNING_UNLOCKED' && return 0
  return 1
}
"$ADB" wait-for-device
"$ADB" root >/dev/null 2>&1 || true
"$ADB" shell cmd lock_settings set-disabled --user 0 true >/dev/null 2>&1 || true
"$ADB" shell wm dismiss-keyguard >/dev/null 2>&1 || true
"$ADB" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
"$ADB" shell input keyevent 82 >/dev/null 2>&1 || true
"$ADB" shell input swipe 360 1000 360 200 >/dev/null 2>&1 || true
"$ADB" shell wm dismiss-keyguard >/dev/null 2>&1 || true
for attempt in $(seq 1 60); do
  if user_unlocked; then break; fi
  "$ADB" shell input keyevent 82 >/dev/null 2>&1 || true
  "$ADB" shell input swipe 360 1000 360 200 >/dev/null 2>&1 || true
  sleep 2
done
if ! user_unlocked; then
  echo 'Emulator user unlock timed out; diagnostics:'
  "$ADB" shell getprop | tr -d '\r' | grep -iE 'unlock|boot_completed' || true
  "$ADB" shell dumpsys user | tr -d '\r' | grep -iE 'UserInfo|state' | head -20 || true
  "$ADB" shell dumpsys window | tr -d '\r' | grep -iE 'mDreamingLockscreen|mShowingLockscreen|KeyguardShowing' | head -5 || true
  exit 1
fi
"$SDK_ROOT/platform-tools/adb" shell getprop ro.build.version.release
# A user-launched app sits in the active standby bucket; keep alarm delivery
# expectations aligned with that real-world state on the headless emulator,
# which otherwise never interacts with the app.
"$SDK_ROOT/platform-tools/adb" shell am set-standby-bucket io.github.vanzeph.minutrove active
(cd android && ./gradlew app:connectedDebugAndroidTest)
# Denial pass: revoking a runtime permission while the app process runs kills
# it, so the permission flips while nothing is running and the denial class
# starts fresh inside the denied state. The main suite passed above with the
# permission granted; restore it afterwards for reproducible follow-up runs.
"$SDK_ROOT/platform-tools/adb" shell pm revoke io.github.vanzeph.minutrove android.permission.POST_NOTIFICATIONS
"$SDK_ROOT/platform-tools/adb" shell am instrument -w -e class io.github.vanzeph.minutrove.NotificationDenialTest io.github.vanzeph.minutrove.test/androidx.test.runner.AndroidJUnitRunner
"$SDK_ROOT/platform-tools/adb" shell pm grant io.github.vanzeph.minutrove android.permission.POST_NOTIFICATIONS
