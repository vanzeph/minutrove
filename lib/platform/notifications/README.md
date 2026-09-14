# Android completion notifications

`AndroidNotificationScheduler` implements the domain `NotificationScheduler`
port over the `io.github.vanzeph.minutrove/notifications` method channel. The
Android implementation lives in
`android/app/src/main/kotlin/io/github/vanzeph/minutrove/`
(`CompletionNotifications.kt`, `CompletionAlarmReceiver.kt`,
`CompletionRescheduleReceiver.kt`, and the wiring in `MainActivity.kt`).

## Channel contract

| Method | Arguments | Result |
| - | - | - |
| `permission` | – | `granted` \| `denied` \| `notDetermined` \| `restricted` |
| `requestPermission` | `operationId` | same string; one system prompt per new operation ID, replays return the recorded answer |
| `reconcile` | `operationId`, `intents: [{sessionId, sessionRevision, completionId, deadlineUtcMilliseconds\|null, handled}]` | `{permission, delivered: [completionId]}` |
| `openSettings` | – | `bool` |
| `consumeLaunchCompletion` | – | `completionId \| null` (consumed once per tap) |

The iOS counterpart implements the same channel contract; keep both sides in
sync through this document and the implementation design.

## Reconcile semantics

The persisted `NotificationIntent` rows are the single source of truth. One
idempotent `reconcile` call replaces all native OS state to match them, so
start, pause (deadline null), resume (new deadline), end, restore, crash and
reboot recovery all converge through the same call:

- An intent with a deadline arms exactly one alarm keyed by the session ID
  (request code plus a distinct data URI, so sessions never collide).
- An intent with a null deadline cancels that alarm; `handled=true` also
  cancels any posted cue and clears the delivered record.
- Stale OS state from a killed process (alarms, mirror, delivered set) is
  dropped on the next reconcile; the alarm receiver additionally rechecks the
  persisted mirror before posting, so a cue armed before an unreconciled
  pause/end cannot fire as a stale completion.

## Alert and chime dedup

The scheduled notification and the foreground chime share one stable
notification tag, `minutrove.completion.<completionId>`, and the notification
is built with only-alert-once. Whichever path posts first owns the single
audible alert. When the OS delivers the cue while the app is dead,
`reconcile` reports that completion ID in `delivered` so the composition layer
suppresses a duplicate foreground chime, persists
`completionChimeHandled=true`, and the next reconcile clears the shade
notification. Notification taps launch the app through `MainActivity` with
the completion ID as an intent extra; `consumeLaunchCompletion()` reports and
consumes it once so the app can route Home with the settled result.

## Permission and sound

`POST_NOTIFICATIONS` (Android 13+) is requested contextually through
`requestPermission`; pre-13 installs are granted at install time. Denial
mapping: notifications disabled, the runtime permission revoked after a
request, or the completion channel blocked all read as `denied`; an ungranted
runtime permission never requested reads as `notDetermined`. `openSettings`
opens the app's notification settings so the user can re-enable delivery.
The cue uses the existing `minutrove_completion_v1` channel: the packaged
one-shot chime as the channel sound, no vibration, no DND bypass, no
full-screen intent, no insistent repeat. Respecting system volume and
silent/focus settings is delegated to the OS notification sound path.

## Scheduling policy and tested OS restrictions

Delivery is best effort; economic completion always uses the persisted
deadline even if this notification is suppressed or delayed. Verified on the
API 33 emulator in CI (`tool/test_android_chime.sh`,
`CompletionNotificationsTest`):

- Deadline cues fire while the screen is off through an allow-while-idle
  alarm (`RTC_WAKEUP`).
- `setExactAndAllowWhileIdle` is used only while the OS grants exact alarm
  access (`SCHEDULE_EXACT_ALARM`); otherwise the fallback is inexact
  `setAndAllowWhileIdle`, which Doze may batch into a maintenance window.
  Android does not guarantee on-time or guaranteed delivery, and this
  implementation does not claim it.
- AlarmManager alarms do not survive reboot or app update: a protected
  BOOT_COMPLETED / MY_PACKAGE_REPLACED / TIME_SET / TIMEZONE_CHANGED receiver
  re-arms from the persisted mirror, delivering immediately (once) when the
  deadline already passed.
- Runtime permission denial suppresses both scheduling and delivery; a cue is
  re-armed by the next reconcile after the user re-enables notifications.
- Killing the process between a committed pause/end and the next reconcile
  can leave an armed alarm behind; the receiver's mirror recheck drops it.

Residual, honestly not guaranteed: deep Doze can defer inexact delivery
indefinitely until a maintenance window; BOOT_COMPLETED arrives after the
first unlock on credential-encrypted storage; emulator coverage does not
substitute for physical-device lock, reboot, vendor Doze tweaks and vendor
alarm-killer behavior, which remain separate device acceptance per the design.

## Composition notes for the app integration task

Construct one `AndroidNotificationScheduler` (or the iOS counterpart) with
the app's channels. After every committed session mutation and at lifecycle
start/resume, call `reconcile` with the persisted intents from the store:
`reconcileDetailed` additionally returns the delivered set needed to decide
between acknowledging an OS-delivered completion (mark handled without the
foreground chime) and playing the one-shot `CompletionChime` in the
foreground. Route Home on `consumeLaunchCompletion()`. Use
`openSystemSettings` for the Settings denied-notification action. Persist
`completionChimeHandled` in the same transaction that acknowledges the cue;
never replay a handled completion after restart.
