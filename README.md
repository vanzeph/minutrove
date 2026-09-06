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
| Android build tools | JDK 17, Gradle 9.3.1, AGP 9.1.0, Kotlin plugin 2.4.0 |
| iOS minimum | iOS 15.0 |

Android development requires the Android SDK with platform 36 and the command
line tools. Set `ANDROID_HOME` or use `flutter config --android-sdk <path>`.
Resolve any SDK license prompts interactively according to your environment.
iOS development requires macOS, full Xcode, its command line tools selected with
`xcode-select`, and an installed iOS simulator runtime. `flutter doctor -v`
reports missing tools. CI records its actual Xcode, macOS, and SDK versions in
the build logs; host images receive updates independently of the Flutter pin.

## Check and run

```sh
dart format --output=none --set-exit-if-changed lib test
flutter analyze --fatal-infos
flutter test --reporter expanded
flutter devices
flutter run -d <device-id>
```

The smoke tests cover navigation and small-phone layouts at 200% text size,
including labeled minimum-size tap targets. They are not validation of future
product accounting, recovery, or physical-device behavior.

## Native builds

```sh
flutter build apk --debug --no-pub
flutter build ios --simulator --debug --no-codesign --no-pub
```

The Android output is `build/app/outputs/flutter-apk/app-debug.apk`, signed by a
local development key. The unsigned simulator app is
`build/ios/iphonesimulator/Runner.app`. These commands require the platform tools
above. Release signing is intentionally unconfigured; no credentials are needed
for the foundation checks.

[Native checks](https://github.com/vanzeph/minutrove/actions/workflows/native.yml)
executes fresh-checkout dependency resolution, formatting, analysis, tests, and
both builds. Actions are pinned to immutable commits; package versions and hashes
are locked in `pubspec.lock`. CI prints build checksums and source commits but
does not upload publicly downloadable binaries or create a release.

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
