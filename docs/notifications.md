# Completion notification platform record

Recorded for the completion-notification integrations: iOS (stable identifier
`minutrove.completion.<completionId>`, channel
`io.github.vanzeph.minutrove/notifications`, `SessionNotifications.swift`,
`IosNotificationScheduler`, `CompletionNotifier`) and Android
(`CompletionNotifications.kt`, `CompletionChime.kt`, `CompletionAlarmReceiver`,
`CompletionRescheduleReceiver`, `DurableClock.kt`). Values below come from the
pinned toolchain (Flutter 3.47.2 / Dart 3.13.2, Xcode 16.4 / iOS 18.5 SDK,
Temurin 17.0.20.1+1) and the automated checks listed at the end. This file
records actual observed behavior and known limits; it is not a claim about
untested hardware paths.

## Verified behavior (simulator, automated)

| Behavior | Evidence |
| --- | --- |
| Without authorization the center silently holds nothing: `add` reports no error but `getPendingNotificationRequests` stays empty (observed on the Xcode 16.4 / iOS 18.5 simulator in CI). Pending registration is observable under provisional authorization, which iOS grants without a prompt; that path is asserted in the native suite. | CI run of `RunnerTests.testSyncRequestsReplacesStableIdentifierAndRemovesStale`; integration raw-channel sync asserts the same contract on every run. |
| Under observable authorization, re-adding a request with the same identifier replaces the pending one; pause and end reconcile to an empty pending set in every authorization state. | Same tests above. |
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
  `openSystemSettings` for that state. The `.alert`/`.sound` permission prompt
  requires a human tap and cannot be accepted from an automated test; the
  native suite therefore requests `.provisional` authorization (quietly
  granted, no prompt) to make pending-state behavior observable on CI. The
  `osOwned` delivery set is derived from what the center actually reports, so
  an unauthorized environment correctly falls back to the immediate chime
  path instead of assuming the OS owns delivery.
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

# Android platform record

`AndroidNotificationScheduler` drives `CompletionNotifications.kt` over the
same channel. Deadline cues are `AlarmManager.RTC_WAKEUP` alarms (exact while
`SCHEDULE_EXACT_ALARM` is granted, otherwise an inexact allow-while-idle
fallback) delivered by `CompletionAlarmReceiver`; reboot, app update, manual
clock edits and timezone changes re-arm through `CompletionRescheduleReceiver`.
`DurableClock` samples `Settings.Global.BOOT_COUNT`, `elapsedRealtime()` and
`currentTimeMillis()`; economic settlement is anchored by the persisted
deadline and monotonic samples, never by alarm delivery.

## Verified behavior (emulator, automated)

Observed on Google APIs emulator images (API 33 arm64-v8a locally; CI runs
API 24/33/36 x86_64) with the pinned toolchain.

| Behavior | Evidence |
| --- | --- |
| One stable cue per completion: the armed deadline fires exactly one notification; the posted cue uses the shared stable tag with only-alert-once, no insistent flag and no full-screen intent. | `CompletionNotificationsTest.runningDeadlineFiresExactlyOneCompletionCue`. |
| Pause cancels the armed alarm completely (no self-completion while paused); resume re-arms only at the new deadline; end plus acknowledgement clears the shade cue. | `CompletionNotificationsTest` pause/resume/end cases. |
| A revoked `SCHEDULE_EXACT_ALARM` degrades to inexact allow-while-idle delivery; delivery still happens, on-time delivery is never asserted. | `CompletionNotificationsTest.deliveryStillHappensWithoutExactAlarmAccess`. |
| Delivery happens with the screen off; a terminated process's stale armed alarm cannot post a cue once the persisted intent has moved on. | `CompletionNotificationsTest.cueStillFiresWhileTheScreenIsOff`, `.alarmLeftBehindByATerminatedProcessCannotPostAStaleCue`. |
| After a reboot (simulated alarm wipe plus `BOOT_COMPLETED`), a surviving future deadline re-arms and fires; a run whose deadline passed while powered off delivers at most once even when the receiver runs twice. | `CompletionNotificationsTest.rebootReceiver*`. |
| Reconcile converges from arbitrary stale OS state: cues no longer scheduled are cancelled, and arbitrary crash-gap state self-heals. | `CompletionNotificationsTest.reconciliationConvergesFromArbitraryStaleOsState`. |
| With `POST_NOTIFICATIONS` revoked (API 33+), undetermined and denied read distinctly after the one contextual request, nothing is armed or delivered while delivery is impossible, and the system-settings action is offered. | `NotificationDenialTest`, run by `tool/android_instrumented.sh` with the permission revoked while no process runs. |
| The bundled chime decodes (1070–1090 ms), plays exactly once through `MediaPlayer`, and the notification sound is the packaged asset with no DND bypass or vibration. | `CompletionChimeTest`. |
| Manual forward clock edits move the RTC cue: a deadline passed by the edit delivers exactly once through the `TIME_SET` re-arm path; the durable clock keeps the same boot id, wall time follows the edit and monotonic time stays continuous. Manual backward edits re-arm the still-future deadline instead of firing it. | `ClockChangeTest`, using `su 0 date` on the rooted-by-default Google APIs image. |
| Notification taps route to the single-top entry with the completion identity; malformed identities are dropped; a regular launcher entry routes nowhere. End-to-end tap-through needs a foreground app process and stays on the device acceptance list. | `CompletionNotificationsTest.completionCueTapRoutes...`. |

## Recorded Android platform limits

- Alarms are wall-clock anchored (`RTC_WAKEUP`): a manual clock edit moves
  cue delivery, and reboot or app update clears alarms entirely; the receiver
  re-arms from the persisted intents on `BOOT_COMPLETED`,
  `MY_PACKAGE_REPLACED`, `TIME_SET` and `TIMEZONE_CHANGED`. Settlement stays
  anchored by the durable clock and persisted deadline.
- Exact alarms are opportunistic: without `SCHEDULE_EXACT_ALARM` (denied by
  default for newly installed apps targeting API 33+ until granted) Doze may
  batch delivery into a maintenance window. On-time delivery is not asserted
  and never required for correct settlement.
- Pre-Android 13 installs have no runtime prompt: notifications are enabled
  by default and the OS denial path is the Settings toggle; the automated
  denial pass therefore runs only on API 33+ and the pre-33 branch of the
  denial class covers the state mapping.
- A live runtime-permission revoke kills the app process, so denial coverage
  flips the permission while nothing is running and launches the denial class
  separately.
- `BOOT_COUNT` is readable from API 24 (the supported minimum), so the boot
  identity is never inferred from wall time.
- Automated clock edits run on API 26+ emulator images only: the oldest
  images' toybox `date` SET parsing is unreliable and destabilizes the
  framework process, so `ClockChangeTest` skips below API 26 and manual
  clock-change verification on Android 7 stays on the device acceptance
  list.

## Remaining physical-device acceptance (Android)

Not claimed as verified on hardware: real lock-screen and heads-up banner
appearance, OEM scheduler variations (vendor Doze implementations, aggressive
battery managers), audibility through a physical silent/vibrate switch or
Focus mode, heads-up behavior at screen-off with a real display, the
human-tap permission prompt decision, notification-tap cold start on a
physical device, and real (non-simulated) reboot and manual clock edits
through system settings. A missing physical device remains a delivery gate,
never a passed test.

## Reproducing the automated evidence

```sh
flutter test test/platform/ios_notification_scheduler_test.dart \
  test/platform/completion_notifier_test.dart
bash tool/test_ios_chime.sh        # includes the native scheduling tests
bash tool/integration_ios.sh       # real-channel sync + suppressed-sound flow;
                                   # also runs the native scheduling suite on
                                   # every simulator leg (iOS 18.5 and 26.2)
# Android, one emulator boot per API level (24/33/36):
MINUTROVE_ANDROID_INSTRUMENTED=1 bash tool/integration_android.sh 33
bash tool/test_android_chime.sh 36 # standalone instrumented entry point
```
