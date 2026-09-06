#!/usr/bin/env bash
# Explicit device selection prevents accidentally running on a different target.
set -euo pipefail
cd "$(dirname "$0")/.."
device="${1:?Usage: bash tool/integration.sh DEVICE_ID}"
python3 tool/verify_toolchain.py
flutter pub get --enforce-lockfile
flutter test integration_test --no-pub --reporter expanded -d "$device"
