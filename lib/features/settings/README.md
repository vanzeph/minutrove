# Settings, onboarding, backup and help

Concise optional onboarding, the Settings surface, manual backup/restore and
in-app help. Every screen receives its repositories and adapters from the
composition root; nothing here selects a database, clock or platform channel.

## Onboarding

`OnboardingFlow` is skippable at every step, creates no sample items and
embeds no hardcoded goals, prices or durations. The stored reporting timezone
is shown once and can be corrected before continuing; skipping writes
nothing. Notifications are asked for contextually and a denied answer links
to the system settings. The composition root decides when to show the flow.

## Settings overview

`SettingsScreen` states the local-only property up front and routes to
backup, timezone, notifications and About. Cancelling any sub-screen changes
nothing.

- `TimezoneScreen` edits the stored IANA reporting zone. Changes apply
  prospectively; earlier activity keeps its frozen day assignments.
- `NotificationsScreen` shows the live permission status, the contextual ask
  and the system-settings action for a denied decision, with the reminder
  that sessions settle on their deadline regardless of delivery.
- `AboutScreen` carries the app license, dependency and asset notices
  (through Flutter's license registry), the local-diagnostics explanation and
  the in-app help topics.
- `BackupScreen` discloses the unencrypted backup property before any
  share-sheet hand-off. Export requires no active session. Restore picks a
  file through the OS picker, inspects it into a temporary database, shows
  source date and record counts, and replaces current data only after the
  explicit in-app confirmation bound to that exact file digest. Cancellation,
  invalid or newer files and storage failures leave current data unchanged;
  a successful replacement calls `onRestored` so the composition root can
  rebuild repositories on the reopened database.

## File adapters

OS file access lives behind the `BackupFilePicker` and `BackupFileSharer`
interfaces in `lib/platform/files`; see that README for the adapter contract.

Validation:

```sh
flutter test test/features/settings_test.dart test/features/onboarding_test.dart \
  test/features/backup_screen_test.dart test/platform/backup_files_test.dart
```
