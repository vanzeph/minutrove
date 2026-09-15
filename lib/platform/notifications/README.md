# Completion notifications

`IosNotificationScheduler` implements the domain `NotificationScheduler` port
for iOS over the method channel `io.github.vanzeph.minutrove/notifications`,
backed by `SessionNotifications.swift` and `UserNotifications`. Android
implements the same port with its own adapter.

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

Recorded iOS platform limits and device-only acceptance live in
[docs/notifications.md](../../docs/notifications.md).
