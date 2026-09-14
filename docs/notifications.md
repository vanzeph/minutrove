# Completion notification platform record

Recorded for the iOS completion-notification integration (stable identifier
`minutrove.completion.<completionId>`, channel
`io.github.vanzeph.minutrove/notifications`, `SessionNotifications.swift`,
`IosNotificationScheduler`, `CompletionNotifier`). Values below come from the
pinned toolchain (Flutter 3.47.2 / Dart 3.13.2, Xcode 16.4, iOS 18.5 SDK) and
the automated checks listed at the end. This file records actual observed
behavior and known limits; it is not a claim about untested hardware paths.

## Verified behavior (simulator, automated)

| Behavior | Evidence |
| --- | --- |
| Desired-state sync registers pending requests even before authorization is decided; delivery alone waits for authorization. | `RunnerTests.testSyncRequestsReplacesStableIdentifierAndRemovesStale`, integration test raw-channel sync. |
| Re-adding a request with the same identifier replaces the pending one; pause and end reconcile to an empty pending set. | Same tests above. |
| The deadline trigger is a non-repeating `UNCalendarNotificationTrigger` interpreted in UTC (`dateComponents.timeZone = UTC`); without an explicit zone iOS would interpret the fields in the device's current zone and the deadline would drift. | `RunnerTests.testDeadlineRequestKeepsStableIdentifierAndUtcTrigger` asserts `nextTriggerDate()` within 1 s of the UTC deadline. |
| One audible foreground presentation per completion per process: a scheduled cue that already sounded suppresses the immediate fallback (`presentOptions` dedup set). | `RunnerTests.testForegroundPresentationSoundsOncePerCompletion`. |
| A tap arriving before the Dart handler exists (cold start) is queued and flushed exactly once on activation; unrelated identifiers never route. | `RunnerTests.testColdStartTapIsQueuedUntilForwardingActivatesThenDeduplicates`. |
| A settled permission decision answers `requestAuthorization` without a second prompt; provisional/ephemeral authorization still delivers and maps to `granted`. | `permissionString` mapping test plus the documented `UNUserNotificationCenter` contract exercised by the adapter tests. |
| While permission is denied the app schedules nothing, keeps settlement exact, and still consumes the one-shot chime marker (submitted then suppressed) exactly once. | Dart adapter tests, `CompletionNotifier` tests, and the iOS integration test on a fresh simulator (status `notDetermined`). |

## Recorded iOS platform limits

- The system holds at most 64 pending local notification requests per app;
  Minutrove schedules at most one (single active-session slot), so the cap is
  unreachable by design.
- Notification sounds are capped at 30 seconds by the OS; the bundled chime is
  1.08 s. Custom sounds respect the ringer/silent switch, Focus and
  notification sound settings, and `interruptionLevel = .active` never breaks
  through them. A suppressed sound never affects settlement: the deadline,
  ledger and handled-marker transactions are independent of delivery.
- Wall-clock edits move `UNCalendarNotificationTrigger` delivery because the
  trigger resolves against device time at delivery; economic completion is
  anchored by the durable clock and persisted deadline instead, and every
  lifecycle transition resynchronizes the desired request.
- Pending and delivered notifications survive process termination and relaunch
  (they are owned by the system); `CompletionNotifier.startup()` therefore
  marks any terminal intent handled without replaying sound, and the next
  sync removes requests no persisted intent asks for.
- Tapping a delivered notification removes it (system behavior); the app never
  re-adds a request for a completed session, so no repeated banner or chime
  can follow a tap.
- Authorization can only be changed by the user: a denied app receives
  `denied` forever until Settings changes, and the adapter surfaces
  `openSystemSettings` for that state. The permission prompt itself requires
  a human tap and cannot be accepted from an automated test.
- The XCTest-driven simulator cannot lock the screen, change the ringer, or
  receive a hardware Focus state; those paths stay on the physical-device
  native acceptance list below.

## Remaining physical-device acceptance

Not claimed as verified here: lock-screen delivery and sound, silent-switch
and Focus audibility, banner appearance on a real device, the human-tap
permission prompt flow, and delivery timing under Low Power Mode. These follow
the implementation design's native acceptance requirement to record actual
OS/device/toolchain versions; a missing device is a delivery gate, not a
passed test.

## Reproducing the automated evidence

```sh
flutter test test/platform/ios_notification_scheduler_test.dart \
  test/platform/completion_notifier_test.dart
bash tool/test_ios_chime.sh        # includes the native scheduling tests
bash tool/integration_ios.sh       # real-channel sync + suppressed-sound flow
```
