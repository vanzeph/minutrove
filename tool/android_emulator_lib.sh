#!/usr/bin/env bash
# Shared helpers for booting a headless Android emulator at a specific API
# level and waiting until it is genuinely usable (boot completed AND user 0
# unlocked). Sourced by tool/integration_android.sh and
# tool/test_android_chime.sh; not executable on its own.
#
# Usage after sourcing:
#   minutrove_emulator_boot <api-level> <abi> <avd-name>
#     - installs the system image if missing, creates the AVD, boots it, and
#       waits for adb, sys.boot_completed and an unlocked user.
#     - sets the globals MINUTROVE_ADB (adb binary) and
#       MINUTROVE_EMULATOR_PID, and registers an EXIT trap that kills the
#       emulator and prints the tail of its log on failure paths.
#   minutrove_emulator_device
#     - prints the adb device id of the booted emulator.

minutrove_emulator_boot() {
  local api="$1"
  local abi="$2"
  local name="$3"
  SDK_ROOT="${ANDROID_HOME:?Android SDK is required}"
  local image="system-images;android-${api};google_apis;${abi}"
  # Recent SDK tools and emulator releases may choose different default homes.
  # Use one explicit AVD registry and image directory per boot.
  export ANDROID_AVD_HOME="${RUNNER_TEMP:-/tmp}/minutrove-avd-${name}"
  mkdir -p "$ANDROID_AVD_HOME"
  printf 'y\n' | "$SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" "$image" >/dev/null
  printf 'no\n' | "$SDK_ROOT/cmdline-tools/latest/bin/avdmanager" create avd \
    --force --name "$name" --path "$ANDROID_AVD_HOME/${name}.avd" --package "$image"
  # Modern images default to a userdata partition several GB in size; the
  # test suites need far less, and CI runners have limited free space. The
  # emulator reads the FIRST occurrence of a duplicated key, so replace any
  # existing line instead of appending a second one.
  local config="${ANDROID_AVD_HOME}/${name}.avd/config.ini"
  if grep -q '^disk.dataPartition.size' "$config"; then
    sed -i.bak 's/^disk.dataPartition.size.*/disk.dataPartition.size=2G/' "$config"
    rm -f "${config}.bak"
  else
    echo "disk.dataPartition.size=2G" >> "$config"
  fi
  "$SDK_ROOT/emulator/emulator" -list-avds
  : > "${ANDROID_AVD_HOME}/emulator.log"
  "$SDK_ROOT/emulator/emulator" -avd "$name" -no-window -no-audio \
    -no-boot-anim -no-snapshot -gpu swiftshader_indirect \
    > "${ANDROID_AVD_HOME}/emulator.log" 2>&1 &
  MINUTROVE_EMULATOR_PID=$!
  trap 'tail -100 "${ANDROID_AVD_HOME}/emulator.log"; \
    kill "${MINUTROVE_EMULATOR_PID}" 2>/dev/null || true' EXIT
  MINUTROVE_ADB="$SDK_ROOT/platform-tools/adb"
  local attempt
  for attempt in $(seq 1 60); do
    kill -0 "$MINUTROVE_EMULATOR_PID" || { echo 'Emulator exited before connecting'; exit 1; }
    if "$MINUTROVE_ADB" get-state 2>/dev/null | grep -q '^device$'; then break; fi
    sleep 2
  done
  "$MINUTROVE_ADB" get-state
  for attempt in $(seq 1 120); do
    if [[ "$("$MINUTROVE_ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]]; then break; fi
    sleep 2
  done
  [[ "$("$MINUTROVE_ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]] || { echo 'Emulator boot timed out'; exit 1; }
  # boot_completed alone can precede credential-encrypted storage availability;
  # runtime permission grants and notification posts fail while user 0 is locked.
  "$MINUTROVE_ADB" wait-for-device
  "$MINUTROVE_ADB" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  "$MINUTROVE_ADB" shell wm dismiss-keyguard >/dev/null 2>&1 || true
  "$MINUTROVE_ADB" shell input keyevent 82 >/dev/null 2>&1 || true
  "$MINUTROVE_ADB" shell input swipe 360 1000 360 200 >/dev/null 2>&1 || true
  "$MINUTROVE_ADB" shell wm dismiss-keyguard >/dev/null 2>&1 || true
  # Try every headless unlock technique, then wait for either the unlock
  # property or the user manager reporting the running user as unlocked.
  local users
  for attempt in $(seq 1 60); do
    users="$("$MINUTROVE_ADB" shell dumpsys user 2>/dev/null | tr -d '\r' || true)"
    if [[ "$users" == *"RUNNING_UNLOCKED"* ]]; then return 0; fi
    if [[ "$("$MINUTROVE_ADB" shell getprop sys.user.0.unlock_completed 2>/dev/null | tr -d '\r' || true)" == 1 ]]; then return 0; fi
    # API 24 images predate both markers; a logged-in system user plus a
    # stopped boot animation is the equivalent readiness signal there.
    if [[ "$("$MINUTROVE_ADB" shell getprop init.svc.bootanim 2>/dev/null | tr -d '\r' || true)" == "stopped" &&
      "$users" == *"Last logged in: +"* ]]; then return 0; fi
    "$MINUTROVE_ADB" shell input keyevent 82 >/dev/null 2>&1 || true
    "$MINUTROVE_ADB" shell input swipe 360 1000 360 200 >/dev/null 2>&1 || true
    sleep 2
  done
  echo 'Emulator user unlock timed out; diagnostics:'
  "$MINUTROVE_ADB" shell getprop | tr -d '\r' | grep -iE 'unlock|boot_completed' || true
  "$MINUTROVE_ADB" shell dumpsys user | tr -d '\r' | grep -iE 'UserInfo|state' | head -20 || true
  "$MINUTROVE_ADB" shell dumpsys window | tr -d '\r' | grep -iE 'mDreamingLockscreen|mShowingLockscreen|KeyguardShowing' | head -5 || true
  exit 1
}

minutrove_emulator_device() {
  local device
  device="$("$MINUTROVE_ADB" devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
  [[ -n "$device" ]] || { echo 'No emulator device found'; exit 1; }
  printf '%s' "$device"
}
