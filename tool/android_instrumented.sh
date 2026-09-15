#!/usr/bin/env bash
set -euo pipefail
# Runs the native instrumented suites on an already-booted, unlocked emulator:
# the behavioral notification scheduling tests (grant baseline), the chime and
# durable-clock tests, the clock-change tests, and — on API 33+, where the
# runtime POST_NOTIFICATIONS permission exists — the denial pass with the
# permission revoked while no app process runs. The gradle-connected main pass
# runs with the permission granted; its task uninstalls both APKs afterwards,
# so they are reinstalled before the direct denial instrumentation call and
# the permission is restored afterwards for reproducible follow-up runs.
#
# Environment: ANDROID_HOME, MINUTROVE_ADB (adb binary). The repository root
# must be the working directory.
ADB="${MINUTROVE_ADB:-${ANDROID_HOME:?Android SDK is required}/platform-tools/adb}"
SDK_ROOT="${ANDROID_HOME:?Android SDK is required}"
"$ADB" shell getprop ro.build.version.release
"$ADB" shell getprop ro.build.version.sdk
# A user-launched app sits in the active standby bucket; keep alarm delivery
# expectations aligned with that real-world state on the headless emulator,
# which otherwise never interacts with the app. Best effort: an adb transport
# hiccup here must not fail the run under set -e.
"$ADB" shell am set-standby-bucket io.github.vanzeph.minutrove active >/dev/null 2>&1 || true
"$ADB" get-state >/dev/null
# --rerun: gradle marks connected tasks up-to-date across devices when the
# APKs are unchanged, which would silently skip execution on a second device
# (for example API 33 followed by API 36 in one checkout).
(cd android && ./gradlew app:connectedDebugAndroidTest --rerun)
api_level="$("$ADB" shell getprop ro.build.version.sdk | tr -d '\r')"
if [[ "$api_level" -ge 33 ]]; then
  # Denial pass: revoking a runtime permission while the app process runs kills
  # it, so the permission flips while nothing is running and the denial class
  # starts fresh inside the denied state.
  "$ADB" install -r build/app/outputs/flutter-apk/app-debug.apk >/dev/null
  "$ADB" install -r build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk >/dev/null
  "$ADB" shell pm revoke io.github.vanzeph.minutrove android.permission.POST_NOTIFICATIONS
  "$ADB" shell am instrument -w -e class io.github.vanzeph.minutrove.NotificationDenialTest io.github.vanzeph.minutrove.test/androidx.test.runner.AndroidJUnitRunner
  "$ADB" shell pm grant io.github.vanzeph.minutrove android.permission.POST_NOTIFICATIONS
else
  echo "API ${api_level}: no runtime POST_NOTIFICATIONS denial pass (pre-33 installs deliver by default; the denial class skips itself there)."
fi
