# Cross-platform backup portability record

This file records how manual iOS/Android backup transfer is verified for the
portable v1 format ([backup format](backup-format.md)), and which platforms
and versions the evidence covers. It records actual observed behavior from the
automated checks listed below; it is not a claim about untested hardware
paths. Physical-device file sharing (AirDrop, USB, cloud drives) is a manual
step outside these gates; the bytes under test are exactly what the export
screen hands to the OS file picker/share sheet.

## Approach

The same deterministic multi-year history is rebuilt through the real product
repositories on every platform (host FFI SQLite, iOS simulator SQLite, Android
emulator SQLite). Every input is pinned — UUIDs, operation serials, the
sampled clock and the reporting zone — so a committed reference artifact
(`test/data/fixtures/portability-v1.minutrove`, SHA-256 pinned in
`test/support/backup_portability.dart`) defines the transferable bytes:

- **Export on each platform equals the reference bytes.** A platform whose
  export reproduces the reference produces exactly the file every other
  platform produces; the digest assertion makes this a byte-for-byte claim.
- **Restoring the reference on a platform is restoring the other platform's
  file.** Because both platforms export identical bytes, restoring the
  reference on iOS and on Android covers both transfer directions.
- After restore, the full durable domain state (wallet, award balances,
  remainders, achievements, items with archive state, groups, settings,
  ledger) and a frozen Stats battery (every period, category, metric, item —
  including archived history — and budget currency) are compared for exact
  equality against the source store. The restored store must also keep
  serving ordinary commands.
- Malformed inputs (flipped payload byte, truncated tail, a future version
  with a well-formed integrity block, foreign pinned currency metadata) fail
  with typed errors and leave the live original readable and writable.
  Interrupted replacement (safety-copy verification failure and
  reopen-after-rename failure, injected through the fault database on the
  host) retains a usable original. On-device suites cover the malformed
  classes; interruption injection is a host capability.

The scenario data intentionally covers: ledger history across 2023–2026
(including a leap day, a local-midnight interval split and the 2023 Berlin
fall-back transition), every pinned currency precision class (USD 2, JPY 0,
BHD 3 minor digits), an archived Quest and an archived Award that keeps its
balance, five paid daily-goal achievements across four calendar years, and
non-zero Coins/Gems accrual remainder carry.

## Reference artifact

| Property | Value |
| --- | --- |
| Path | `test/data/fixtures/portability-v1.minutrove` |
| Size | 137 352 bytes |
| SHA-256 | `6877409fc34fa4fa231159a10697372528ed676ab481ea78ac31be9392d23b6c` |
| Format | `minutrove` version 1, unencrypted canonical JSON |
| Source schema | 2 (current database schema at generation) |
| Currency metadata | `pinned-iso4217-v1` |
| Created UTC | 2026-03-15 08:30 (09:30 Europe/Berlin) |

Record counts: 13 sessions, 46 operations, 54 ledger entries, 12 item
revisions, 7 items (2 archived), 1 current group (a removed group survives
only in historical revisions), 4 award balances, 6 accrual remainders,
3 goal revisions, 5 achievements, 1 wallet, 1 settings (Europe/Berlin).

Regenerate and re-pin deterministically with the pinned toolchain:

```sh
flutter pub get --enforce-lockfile
dart run tool/generate_portability_fixture.dart
```

The generator prints the SHA-256 to copy into
`portabilityReferenceSha256`. Regeneration is byte-identical by construction;
redemption ledger identities are derived from the operation ID and posting
ordinal (like session and expense identities), so replaying a committed
history never mints new IDs. If the digest changes, the portable contract
changed: update this record and the constant together.

## Verified platforms

| Platform | SQLite under test | Evidence |
| --- | --- | --- |
| Host (CI `checks`, ubuntu-24.04) | sqflite_common_ffi | `test/data/backup_portability_test.dart`: reference regeneration, restore state/Stats equality, export-to-second-store equality, stale confirmation rejection, four malformed classes, two interrupted-replacement injections. |
| iOS simulator, iPhone 16 / iOS 18.5, Xcode 16.4 (CI `integration-ios`, macos-15) | platform sqflite | `integration_test/app_test.dart` portability tests: reference-byte export, transferred-backup restore with state/Stats equality, four malformed classes against the on-device original. |
| iOS simulator, iPhone 17 / iOS 26.2, Xcode 26.3 (CI `integration-ios` matrix leg, macos-15) | platform sqflite | Same Dart suite via the same script; the leg re-verifies the identical export bytes and restore contract on the newest-OS runtime the runner image provides. |
| Android 13 (API 33) google_apis x86_64 emulator (CI `integration-android`, ubuntu-24.04) | platform sqflite | Same Dart suite via `tool/integration_android.sh` on a headless accelerated emulator. |
| Pinned toolchain | Flutter 3.47.2 (`d3b14c876900e553bc736ca19295fc09e3853e8e`), Dart 3.13.2 | Enforced by `tool/verify_toolchain.py` in every script and CI job. |

## Recorded limits

- Real device-to-device transfer over OS share sheets is a manual step; these
  gates verify the bytes and the restore path, which is everything the app
  controls.
- Interruption injection during file replacement runs on the host fault
  database; the on-device suites verify the malformed-file classes and that
  the original remains usable, matching what a device can inject without
  extra privileges.
- The backup remains unencrypted by design (v1); portability verification
  does not change that property.
