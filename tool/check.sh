#!/usr/bin/env bash
# The same checks run locally and on every pull request.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tool/verify_toolchain.py
flutter pub get --enforce-lockfile
python3 tool/generate_chime.py --check
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze --fatal-infos --no-pub
flutter test --no-pub --reporter expanded test
