# Completion notifications

Both platforms implement the domain `NotificationScheduler` port over the
method channel `io.github.vanzeph.minutrove/notifications`; iOS through
`IosNotificationScheduler` (`SessionNotifications.swift`, `UserNotifications`)
and Android through `AndroidNotificationScheduler`
(`CompletionNotifications.kt` and its receivers under `android/`). Reconcile
is desired-state synchronization, not an economic command: each adapter
schedules exactly one local notification for the live run deadline, removes
identifiers no persisted intent asks for, and deduplicates foreground
presentation against OS delivery so one completion alerts at most once.

`CompletionNotifier` composes a scheduler with the one-shot `CompletionChime`
and the persisted `completionChimeHandled` marker; notification taps are
deduplicated and routed Home with the settled result. Recorded platform
limits and device-only acceptance live in
[docs/notifications.md](../../docs/notifications.md).

# iOS adapter

## Adapter contract

`permission()` reads the current authorization; `provisional` and `ephemeral`
statuses map to `granted` because they still deliver, leaving audibility to
the OS sound setting. `requestPermission` is the contextual prompt: it is
asked once per operation ID and iOS answers a settled decision without
prompting again. `openSystemSettings` launches the system notification pane
for the denied-permission Settings state.

`reconcile` is desired-state synchronization, not an economic command. It
schedules exactly one local notification for each persisted intent with a
live deadline — but only while permission is granted — using the stable
identifier `minutrove.completion.<completionId>`. Pause (null deadline), end,
restore and crash recovery all reduce to the same sync: identifiers that no
intent asks for are removed, and a rescheduled deadline replaces its own
identifier. Native calls are serialized so concurrent lifecycle callbacks
cannot interleave an add with a removal. The sync answers with the pending
prefixed identifiers, which becomes the OS-delivery ownership set exposed to
`CompletionNotifier`.

Every error is the retryable typed `StorageUnavailable`; platform details
never leave the adapter, and a failed sync drops OS ownership so a later
foreground completion can fall back to the immediate chime.

## CompletionNotifier

`CompletionNotifier` owns the exactly-once completion cue and reconciles
after every committed `SessionMutation` (repository results and lifecycle
recovery alike) plus once at `startup()`:

- The scheduled deadline notification owns the single audible cue whenever
  the OS accepted it — foreground presentation, background delivery, lock
  screen or terminated app are all that one request.
- The immediate `CompletionChime` fallback plays only when the app is
  foregrounded, the completion was never OS-owned (for example permission was
  denied) and the persisted `completionChimeHandled` marker is still unset.
  The marker is written before playback is acknowledged; submission failures
  retain the marker because an ambiguous retry could repeat the cue.
- `startup()` never plays: terminal intents found on disk are marked handled,
  so a relaunch after termination cannot replay a completed-session chime.
  Early ends consume their intent the same way and never sound.
- Notification taps forward a deduplicated `NotificationTap` (one routed Home
  transition per completion per process). Native queues a cold-start tap and
  flushes it when the Dart handler activates.

```dart
final scheduler = IosNotificationScheduler();  // one per app lifetime
final notifier = CompletionNotifier(
  store: store,
  scheduler: scheduler,
  chime: const CompletionChime(),
  isForeground: () => /* AppLifecycleState.resumed */,
);
await notifier.startup();                       // before exposing commands
final subscription = lifecycle.results.listen((result) async {
  if (result case Success<SessionMutation>(:final value)) {
    await notifier.onMutation(value);
  }
});
// Settings surfaces use scheduler.requestPermission / openSystemSettings.
```

Validation:

```sh
flutter test test/platform/ios_notification_scheduler_test.dart \
  test/platform/completion_notifier_test.dart
bash tool/test_ios_chime.sh   # native scheduling, tap and presentation tests
```

# Android adapter

`AndroidNotificationScheduler` implements the same port and channel contract;
the Android implementation lives in
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
can suppress a duplicate foreground chime, persist
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
`CompletionNotificationsTest`, `NotificationDenialTest`):

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
  Revoking a runtime permission while the app runs kills the process, so the
  denial test pass is launched by the harness with the permission already
  revoked.
- Killing the process between a committed pause/end and the next reconcile
  can leave an armed alarm behind; the receiver's mirror recheck drops it.

Residual, honestly not guaranteed: deep Doze can defer inexact delivery
indefinitely until a maintenance window; BOOT_COMPLETED arrives after the
first unlock on credential-encrypted storage; emulator coverage does not
substitute for physical-device lock, reboot, vendor Doze tweaks and vendor
alarm-killer behavior, which remain separate device acceptance per the design.

## Composition notes

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

Validation:

```sh
flutter test test/platform/android_notifications_test.dart
bash tool/test_android_chime.sh   # scheduling, denial, lock, reboot tests
```
