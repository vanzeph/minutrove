#!/usr/bin/env bash
set -euo pipefail
# Drive the Dart integration suite on a headless Google APIs emulator at the
# requested API level (default 33), the same emulator baseline family as the
# notification/chime/clock checks. The suite exercises the app's real
# on-device SQLite through the platform sqflite channel; the cross-platform
# backup tests assert this platform exports and restores the pinned reference
# bytes.
#
# Usage: bash tool/integration_android.sh [api-level] [abi]
#   api-level  Android API level of the system image (default 33)
#   abi        system-image ABI (default x86_64; CI runners are KVM x86_64)
#
# Set MINUTROVE_ANDROID_INSTRUMENTED=1 to also run the native instrumented
# notification/chime/clock suites on the same emulator before it shuts down.
cd "$(dirname "$0")/.."
api="${1:-33}"
abi="${2:-x86_64}"
source tool/android_emulator_lib.sh
minutrove_emulator_boot "$api" "$abi" "integration${api}"
device="$(minutrove_emulator_device)"
python3 tool/verify_toolchain.py
flutter pub get --enforce-lockfile
flutter test integration_test --reporter expanded -d "$device"
if [[ "${MINUTROVE_ANDROID_INSTRUMENTED:-0}" == 1 ]]; then
  bash tool/android_instrumented.sh
fi
