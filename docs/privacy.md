# Privacy and data practices

This page records what Minutrove stores, which device capabilities it uses, and
how anyone can re-verify those claims from this repository. It covers the same
facts the app presents in Settings (local storage statement, notifications
status, local diagnostics, backup disclosure) and About & licenses.

Minutrove has no account, no hosted service, no synchronization and no store
distribution. Data is local to one device; the only way data leaves it is a
backup file the user explicitly exports.

## Where data lives

All product data — items, groups, configuration revisions, ended sessions,
ledger entries, wallet and allowance balances, accrual remainders, daily-goal
revisions and achievements, and settings (including the stored reporting
timezone) — lives in one SQLite database:

- The database is `minutrove.db`, created inside the operating system's
  per-app private databases directory (`sqflite.getDatabasesPath()`), which is
  part of the app sandbox on both platforms
  ([lib/app_startup.dart](../lib/app_startup.dart)).
- One small diagnostics file, `minutrove.recovery.log`, may sit next to it
  (see [Local diagnostics](#local-diagnostics)).
- Nothing is written outside the app sandbox except an explicitly exported
  backup file handed to the OS share sheet or file picker.

## Network use

The release app makes **no network requests**:

- No Dart or native source in this repository opens sockets, HTTP clients or
  any analytics, advertising or crash-reporting SDK. The only direct
  dependencies ([pubspec.yaml](../pubspec.yaml)) are storage, rendering,
  crypto-hash and timezone libraries; every package is resolved from `pub.dev`
  at build time and pinned with an archive hash in
  [pubspec.lock](../pubspec.lock).
- The release [AndroidManifest.xml](../android/app/src/main/AndroidManifest.xml)
  declares **no `INTERNET` permission**. The `INTERNET` permission appears only
  in the debug and profile manifests, where the Flutter tool needs it for hot
  reload and debugging; it is not present in release builds.
- The iOS [Info.plist](../ios/Runner/Info.plist) declares no network or
  tracking capabilities and contains no tracking domains.
- Assets are bundled: the font, all icons, the completion chime and the full
  IANA timezone database ship inside the app. There is no runtime download.

CI sets `FLUTTER_SUPPRESS_ANALYTICS: true`, checks out without persisting
credentials, and uploads no app binaries.

## Device permissions

The app requests only what session completion cues need:

| Platform | Permission | Purpose |
| --- | --- | --- |
| Android | `POST_NOTIFICATIONS` | Show the completion notification and play its chime when a session reaches its deadline. |
| Android | `RECEIVE_BOOT_COMPLETED` | Re-arm the pending deadline cue after a device reboot or app update (alarms are cleared by the system). |
| Android | `SCHEDULE_EXACT_ALARM` | Schedule the deadline cue exactly **when the OS grants it**; otherwise the code falls back to an inexact allow-while-idle alarm (see `CompletionNotifications.kt`). Settlement never depends on delivery. |
| iOS | Notification authorization (`.alert`/`.sound`, requested at runtime) | Same purpose; there is no Info.plist usage string because iOS asks through the system prompt. |

Permission is requested contextually, never required: with notifications
denied, sessions still settle exactly on their deadline and no banner or chime
is delivered. Settings → Notifications & sound shows the live status, offers
the system ask, and links to the OS settings page after a denial. The boot and
alarm receivers are not exported and react only to protected system broadcasts.

## Local diagnostics

Recovery events may be recorded in `minutrove.recovery.log` next to the
private database ([recovery_diagnostics.dart](../lib/platform/sessions/recovery_diagnostics.dart)):

- Content is limited to the four fixed event codes `bootChanged`,
  `wallClockForward`, `wallClockBackward` and `recoveryUnavailable` — never
  item names, amounts, identifiers or raw clock readings.
- The log keeps at most 32 entries and 8 KiB, is rewritten atomically, and a
  full or unavailable disk never fails session recovery.
- It is not included in backups (export serializes database records only),
  and it never leaves the device.

The About & licenses screen discloses this in the app.

## Backups are unencrypted

A `.minutrove` backup is **unencrypted** UTF-8 JSON and is fully readable by
anyone who has the file: names, activity, amounts and settings. The export
screen states this before the share sheet, and export is refused while a
session is running. Integrity is protected by a SHA-256 digest (accidental
corruption detection, not authentication). Restoring validates the whole file
into a temporary database, requires explicit confirmation of the exact file,
and keeps a safety copy of the replaced data. The complete portable format,
version compatibility rules and size bounds are specified in
[backup-format.md](backup-format.md).

## Licenses and notices

Original repository content is AGPL-3.0-only ([LICENSE](../LICENSE)). The
About & licenses screen presents the app license, the in-app help topics, and
dependency and asset notices through Flutter's license registry, which
includes the bundled font, icon and artwork notices registered by
`registerTroveAssetLicenses()`. The complete inventory — Nunito Sans (OFL-1.1),
Lucide icons (ISC), original design icons and the original "Pocket Victory"
chime (AGPL-3.0-only), Material icons (Apache-2.0), SQLite/IANA data (public
domain), and the pinned Dart packages — is in
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md), with per-asset upstream
sources and SHA-256 hashes in
[assets/provenance.json](../assets/provenance.json) and
[assets/audio/README.md](../assets/audio/README.md).

## Test and evidence data

Test fixtures, charts and screenshots in this repository are synthetic; no
personal activity data is committed. CI retains only JSON build metadata for
30 days and never publishes binaries or creates releases. Contributors must
keep it that way (see [CONTRIBUTING.md](../CONTRIBUTING.md)).

## Re-verifying from source

```sh
# No network client code in shared sources (`dart:io` appears only for local
# File access; this prints nothing when no network client exists):
grep -rn "HttpClient\|WebSocket\|Socket(" lib/
# Release Android permissions (only notification/alarm/boot entries expected):
grep -n "uses-permission" android/app/src/main/AndroidManifest.xml
# Debug-only INTERNET permission:
grep -l "INTERNET" android/app/src/debug/AndroidManifest.xml \
  android/app/src/profile/AndroidManifest.xml
# Pinned third-party inventory:
grep -E "^  [a-z_]+:" pubspec.lock
# Asset provenance hashes:
python3 - <<'PY'
import hashlib, json
for entry in json.load(open('assets/provenance.json')):
    ok = hashlib.sha256(open(entry['path'], 'rb').read()).hexdigest() == entry['sha256']
    print(('OK  ' if ok else 'FAIL'), entry['path'])
PY
```

Any change that adds a permission, a network capability, a diagnostic field, a
dependency or an asset must update this page,
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) and
[CONTRIBUTING.md](../CONTRIBUTING.md) in the same pull request.
