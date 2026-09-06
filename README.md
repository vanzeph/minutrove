# Minutrove

Turn focused effort into time and budget for activities you value.

Minutrove is a local quest-and-award app for iOS and Android, built with one
Flutter package. The current foundation runs a synthetic Home, Shop, and Stats
preview. Quests, accounting, persistence, and native integrations are upcoming
features; the preview does not create activity or balances.

## Development setup

Install Git, Python 3, and the platform tools below. From the repository root:

```sh
bash tool/install_flutter.sh
export PATH="$PWD/.local/flutter/bin:$PATH"
python3 tool/verify_toolchain.py
flutter pub get --enforce-lockfile
flutter doctor -v
```

The installer verifies the Flutter revision before executing it. It installs
inside ignored `.local/flutter` by default; an optional first argument selects
another SDK directory. An existing SDK at that path must match the pin.

| Component | Pinned version / baseline |
| --- | --- |
| Flutter | 3.47.2 stable, `d3b14c876900e553bc736ca19295fc09e3853e8e` |
| Dart | 3.13.2, bundled with Flutter |
| App identity | `io.github.vanzeph.minutrove` on both platforms |
| App version | 0.1.0, build 1 |
| Android minimum | Android 7.0 / API 24 |
| Android compile / target | API 36, from the pinned Flutter SDK |
| Android NDK | 28.2.13676358, from the pinned Flutter SDK |
| Android build tools | Temurin 17.0.20.1+1, SDK build tools 36.0.0, Gradle 9.3.1 (SHA-256 verified), AGP 9.1.0, Kotlin plugin 2.4.0 |
| CI Apple tools | Xcode 16.4 / iOS SDK and simulator runtime 18.5 |
| iOS minimum | iOS 15.0 |

Android development requires the Android SDK with platform 36 and the command
line tools. Set `ANDROID_HOME` or use `flutter config --android-sdk <path>`.
Resolve any SDK license prompts interactively according to your environment.
iOS development requires macOS, full Xcode, its command line tools selected with
`xcode-select`, and an installed iOS simulator runtime. `flutter doctor -v`
reports missing tools. CI selects Xcode 16.4 explicitly and fails if its expected
iOS 18.5 SDK is absent. Host images receive updates independently; the actual
runner image and OS versions are recorded with each build.

Install the exact Android components with your licensed SDK setup:

```sh
sdkmanager 'platforms;android-36' 'build-tools;36.0.0' 'ndk;28.2.13676358'
```

## Check and run

```sh
bash tool/check.sh
flutter devices
flutter run -d <device-id>
```

The smoke tests cover navigation and small-phone layouts at 200% text size,
including labeled minimum-size tap targets. They are not validation of future
product accounting, recovery, or physical-device behavior.

## Native builds and integration tests

Run the same scripts as CI from a clean checkout:

```sh
bash tool/build_native.sh android
# macOS with Xcode 16.4 selected:
export DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer
bash tool/build_native.sh ios
# Select a booted iOS simulator or connected Android development device:
flutter devices
bash tool/integration.sh <device-id>
```

Every script verifies the Flutter/Dart revision and first resolves dependencies
with `--enforce-lockfile`. Native build/test commands then retain Flutter's normal
Pub phase so it regenerates plugin registration for debug versus release (the
`--no-pub` flag would suppress that step). CI rejects any source/lockfile drift.
`tool/check.sh` formats and analyzes all Dart sources and
runs every unit/widget test in `test/`. `tool/integration.sh` runs all tests in
`integration_test/` on the explicitly selected device; it fails for a missing or
unavailable device. The initial integration smoke checks native launch and
navigation. Add consequential native journeys there as features arrive.

| Output | Build command used by script | Signing / purpose |
| --- | --- | --- |
| `build/app/outputs/flutter-apk/app-debug.apk` | `flutter build apk --debug` | Debug signed; installable development APK |
| `build/app/outputs/bundle/release/app-release.aab` | `flutter build appbundle --release` | Unsigned; cannot be installed directly |
| `build/ios/iphonesimulator/Runner.app` | `flutter build ios --simulator --debug --no-codesign` | No signing identity; Apple Silicon may add an ad-hoc signature |
| `build/ios/archive/Runner.xcarchive` | `flutter build ipa --release --no-codesign` | Unsigned device archive; no IPA export or device install |

The scripts reject certificate-signed Apple outputs and record unsigned or
linker-generated ad-hoc signing accurately. Ad-hoc signatures use no developer
identity or provisioning profile and do not authorize device distribution.
The scripts verify signing state and write `build/evidence/android.json` or
`ios.json` with source commit, dirty-checkout status, app version, actual
toolchain/host, target, size and SHA-256. iOS directories are packaged locally as
`Runner.app.tar.gz` and `Runner.xcarchive.tar.gz` in `build/evidence/` so their
checksums identify the complete output, not just one executable. Retain these
local outputs and manifests when a verified build is needed for comparison or
rollback. Checksums identify that build; timestamps, runner updates and generated
development keys mean separate builds are not claimed to be byte-identical.

[Native checks](https://github.com/vanzeph/minutrove/actions/workflows/native.yml)
runs on pull requests, main, task branches and manual dispatch. Independent jobs
check source quality, build both Android outputs, build both iOS outputs, and
run integration tests on iPhone 16 / iOS 18.5 in an isolated standard
`macos-15-intel` runner (14 GB RAM). The existing reproducible audio-source check
and native Android/iOS one-shot sound tests also remain mandatory in these jobs.
All four jobs must pass before a
routine merge; the merged main run must also pass. No job needs signing secrets
or a paid testing service. Actions use immutable commit pins and checkout does
not persist repository credentials; the workflow token has only `contents: read`.

CI retains **JSON metadata only** for 30 days and also writes it to the run logs
and summary. It never uploads app binaries or creates releases. Device lifecycle,
sound, permissions, physical-device installation and full product acceptance
remain separate gates; a simulator smoke pass does not assert they passed. Keep
fixtures synthetic and exclude personal data and private design documents from
source, logs and evidence.

## Project layout and scope

See [lib/README.md](lib/README.md) for the domain, data, platform, shared UI, and
feature boundaries. Only `android/` and `ios/` are generated platform targets.
There is no web target, hosted service, account, cloud sync, or app distribution.
Product data will remain local, with manual file backup and restore.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the contribution workflow.

## License

Original repository content is licensed under **GNU Affero General Public
License, version 3 only** (`AGPL-3.0-only`), unless an individual file explicitly
states otherwise. See [LICENSE](LICENSE) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
