#!/usr/bin/env bash
set -euo pipefail
# Headless, synthetic instrumented tests on a Google APIs emulator image at
# the requested API level (default 33) so runtime POST_NOTIFICATIONS denial is
# exercised; no signing or artifact upload. Kept as the standalone entry
# point; CI combines this with the Dart integration suite through
# MINUTROVE_ANDROID_INSTRUMENTED=1 to reuse one emulator boot per API level.
#
# Usage: bash tool/test_android_chime.sh [api-level] [abi]
cd "$(dirname "$0")/.."
api="${1:-33}"
abi="${2:-x86_64}"
source tool/android_emulator_lib.sh
minutrove_emulator_boot "$api" "$abi" "chime${api}"
minutrove_emulator_device >/dev/null
flutter pub get --enforce-lockfile
bash tool/android_instrumented.sh
