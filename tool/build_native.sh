#!/usr/bin/env bash
# Build all development/unsigned artifacts without a distribution identity.
set -euo pipefail
cd "$(dirname "$0")/.."
target="${1:?Usage: bash tool/build_native.sh android|ios}"
case "$target" in android|ios) ;; *) echo "Unknown target: $target" >&2; exit 2 ;; esac
python3 tool/verify_toolchain.py
flutter pub get --enforce-lockfile
# Flutter must regenerate plugin registration for each debug/release mode.
# --no-pub suppresses that regeneration and can leak dev plugins into release.
mkdir -p build/evidence
case "$target" in
  android)
    flutter build apk --debug
    flutter build appbundle --release
    ;;
  ios)
    flutter build ios --simulator --debug --no-codesign
    flutter build ipa --release --no-codesign
    ;;
esac
python3 tool/build_evidence.py "$target"
