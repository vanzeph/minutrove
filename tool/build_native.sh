#!/usr/bin/env bash
# Build all development/unsigned artifacts without a distribution identity.
set -euo pipefail
cd "$(dirname "$0")/.."
target="${1:?Usage: bash tool/build_native.sh android|ios}"
case "$target" in android|ios) ;; *) echo "Unknown target: $target" >&2; exit 2 ;; esac
python3 tool/verify_toolchain.py
flutter pub get --enforce-lockfile
mkdir -p build/evidence
case "$target" in
  android)
    flutter build apk --debug --no-pub
    flutter build appbundle --release --no-pub
    ;;
  ios)
    flutter build ios --simulator --debug --no-codesign --no-pub
    flutter build ipa --release --no-codesign --no-pub
    ;;
esac
python3 tool/build_evidence.py "$target"
