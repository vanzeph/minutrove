#!/usr/bin/env python3
"""Fail early when a checkout is being built with a different Flutter/Dart SDK."""
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
actual = json.loads(subprocess.check_output(["flutter", "--version", "--machine"]))
expected = {
    "frameworkVersion": (root / ".flutter-version").read_text().strip(),
    "frameworkRevision": (root / "tool/flutter-revision").read_text().strip(),
    "dartSdkVersion": "3.13.2",
}
for field, value in expected.items():
    if actual.get(field) != value:
        raise SystemExit(f"Expected {field}={value}; got {actual.get(field)}")
print(json.dumps(expected, indent=2))
