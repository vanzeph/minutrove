#!/usr/bin/env bash
# Install the exact source revision; engine and Dart versions come from this SDK.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
sdk_path="${1:-$project_root/.local/flutter}"
revision="$(cat "$project_root/tool/flutter-revision")"
version="$(cat "$project_root/.flutter-version")"

if [[ ! -e "$sdk_path" ]]; then
  git clone --depth 1 --branch "$version" https://github.com/flutter/flutter.git "$sdk_path"
fi
if [[ "$(git -C "$sdk_path" rev-parse HEAD)" != "$revision" ]]; then
  echo "Flutter checkout does not match tool/flutter-revision: $sdk_path" >&2
  exit 1
fi
"$sdk_path/bin/flutter" --version
