#!/usr/bin/env python3
"""Record only build metadata; never upload binaries or local environment dumps."""
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent


def command(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True, stderr=subprocess.STDOUT).strip()


def unsigned_bundle(path):
    with zipfile.ZipFile(path) as archive:
        if any(name.upper().startswith("META-INF/") and
               name.upper().endswith((".RSA", ".DSA", ".EC", ".SF"))
               for name in archive.namelist()):
            raise SystemExit(f"Unexpected signing material in {path.name}")


def apple_signing(path):
    if (path / "embedded.mobileprovision").exists():
        raise SystemExit(f"Unexpected provisioning profile: {path.name}")
    result = subprocess.run(["codesign", "--display", "--verbose=4", str(path)],
                            capture_output=True, text=True)
    if result.returncode != 0 and "not signed at all" in result.stderr:
        return "unsigned"
    # Apple Silicon simulator executables can have linker-generated ad-hoc
    # signatures even with --no-codesign; these use no certificate or identity.
    if (result.returncode == 0 and "Signature=adhoc" in result.stderr and
            "Authority=" not in result.stderr and "TeamIdentifier=not set" in result.stderr):
        return "ad-hoc; no signing identity or provisioning profile"
    raise SystemExit(f"Unexpected Apple signing identity: {path.name}: {result.stderr}")


def artifact(path, target, signing):
    source = ROOT / path
    if not source.exists():
        raise SystemExit(f"Missing build output: {path}")
    if source.is_dir():
        archive = ROOT / "build/evidence" / (source.name + ".tar.gz")
        with tarfile.open(archive, "w:gz") as output:
            output.add(source, arcname=source.name)
        source = archive
    digest = hashlib.sha256()
    with source.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return {"path": str(source.relative_to(ROOT)), "target": target,
            "signing": signing, "sha256": digest.hexdigest(), "bytes": source.stat().st_size}


def main(target):
    os.chdir(ROOT)
    (ROOT / "build/evidence").mkdir(parents=True, exist_ok=True)
    flutter = json.loads(command("flutter", "--version", "--machine"))
    evidence = {
        "source_commit": command("git", "rev-parse", "HEAD"),
        "source_dirty": bool(command("git", "status", "--porcelain", "--untracked-files=normal")),
        "version": next(line.split(":", 1)[1].strip() for line in
                        (ROOT / "pubspec.yaml").read_text().splitlines() if line.startswith("version:")),
        "flutter": {key: flutter[key] for key in
                    ("frameworkVersion", "frameworkRevision", "engineRevision", "dartSdkVersion")},
        "host": {"system": platform.system(), "release": platform.release(),
                 "architecture": platform.machine(), "runner_image": os.getenv("ImageVersion")},
        "verification": "Build and signing checks only; device/product acceptance is separate.",
    }
    if os.getenv("GITHUB_ACTIONS") == "true":
        evidence["run_url"] = (f"{os.environ['GITHUB_SERVER_URL']}/{os.environ['GITHUB_REPOSITORY']}"
                               f"/actions/runs/{os.environ['GITHUB_RUN_ID']}")
        if evidence["source_dirty"]:
            raise SystemExit("Build changed tracked source or generated untracked files; lock them first.")
    if target == "android":
        apk = "build/app/outputs/flutter-apk/app-debug.apk"
        bundle = "build/app/outputs/bundle/release/app-release.aab"
        sdk = os.environ.get("ANDROID_HOME") or os.environ["ANDROID_SDK_ROOT"]
        verification = command(str(Path(sdk) / "build-tools/36.0.0/apksigner"),
                               "verify", "--print-certs", apk)
        if "CN=Android Debug" not in verification:
            raise SystemExit("Expected the development debug certificate")
        unsigned_bundle(ROOT / bundle)
        evidence["java"] = command("java", "-version")
        evidence["android"] = {"compile_sdk": 36, "build_tools": "36.0.0", "ndk": "28.2.13676358"}
        evidence["artifacts"] = [artifact(apk, "android-development-apk", "debug signed"),
                                 artifact(bundle, "android-release-aab", "unsigned")]
    elif target == "ios":
        simulator = "build/ios/iphonesimulator/Runner.app"
        archive = "build/ios/archive/Runner.xcarchive"
        simulator_signing = apple_signing(ROOT / simulator)
        archive_signing = apple_signing(ROOT / archive / "Products/Applications/Runner.app")
        evidence["xcode"] = command("xcodebuild", "-version")
        evidence["ios_sdk"] = command("xcrun", "--sdk", "iphoneos", "--show-sdk-version")
        evidence["macos"] = command("sw_vers", "-productVersion")
        evidence["artifacts"] = [artifact(simulator, "ios-simulator-app", simulator_signing),
                                 artifact(archive, "ios-device-xcarchive", archive_signing + "; no IPA exported")]
    else:
        raise SystemExit("Expected android or ios")
    encoded = json.dumps(evidence, indent=2) + "\n"
    (ROOT / f"build/evidence/{target}.json").write_text(encoded)
    print(encoded)
    if os.getenv("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write(f"### {target} build evidence\n\n```json\n{encoded}```\n")


if __name__ == "__main__":
    main(sys.argv[1])
