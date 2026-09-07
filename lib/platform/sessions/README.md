# Durable clock and session recovery

Use `NativeClock` for the iOS/Android application. Every `await clock.now()` calls
the native bridge for one fresh UTC, boot identity, and monotonic sample. There
is no Dart `Stopwatch` or cached wall/uptime pair. The `Clock` port returns
`FutureOr<ClockReading>` so deterministic clocks can remain synchronous; all
repository consumers await it after operation replay lookup and before writes.
The native request has a two-second timeout. Missing, malformed or unavailable
samples return retryable `StorageUnavailable`, without partial economic writes.

Android uses [elapsedRealtime](https://developer.android.com/reference/android/os/SystemClock#elapsedRealtime())
and the readable API 24+ [BOOT_COUNT](https://developer.android.com/reference/android/provider/Settings.Global#BOOT_COUNT).
iOS uses `clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)`, the nanosecond equivalent
of Apple's [continuous clock](https://developer.apple.com/documentation/kernel/1646199-mach_continuous_time),
and `sysctlbyname("kern.bootsessionuuid")`, also used by
[WebKit's boot identity helper](https://github.com/WebKit/WebKit/blob/main/Source/WTF/wtf/UUID.cpp).
Both clocks include sleep. The bridge rejects an unavailable boot marker instead
of inferring identity from a wall-clock boot date that can change when time is set.
Raw clock readings stay in local session records, never diagnostic output.

Construct one lifecycle owner for the open database, using the same session
repository, clock and calendar as every other command:

```dart
const clock = NativeClock();
final sessions = SqliteSessionRepository(
  store: store,
  clock: clock,
  calendar: calendar,
);
final lifecycle = SessionLifecycle(
  clock: clock,
  recovery: SessionRecovery(
    store: store,
    sessions: sessions,
    recordDiagnostic: LocalRecoveryDiagnostics(
      File('$privateDataDirectory/session-recovery.log'),
    ).record,
  ),
);
final subscription = lifecycle.results.listen(handleCommittedRecovery);
final initialRecovery = await lifecycle.start();
// Handle failure/retry before exposing session commands. Use refreshed revisions.
// On shutdown: await lifecycle.dispose(), cancel subscription, then close store.
```

`start()` reconciles the persisted slot. The observer checkpoints on background
transitions, recovers on resume, checkpoints running sessions every 30 seconds
in the foreground, and schedules a one-shot wakeup for the projected remaining
time. Timer callbacks only ask the repository to reconcile; the clock and SQLite
transaction determine progress. Startup never relies on a background callback
having run before termination. Concurrent callbacks share a pending command.
Paused sessions hold the slot and never accrue elapsed time during recovery.
Results contain committed state or a typed failure; UI consumers decide how to
show storage errors and return Home when a completion releases the slot.

Same-boot recovery uses persisted monotonic anchors. After a boot change it
estimates progress from the persisted UTC deadline, bounded to zero and the
remaining run duration. A backwards wall clock settles zero and reanchors the
remaining deadline. A late recovery completes once, using the existing stable
completion identity, ledger, fractional remainders, daily achievements and
notification intent in the same transaction. No schema or stored record format
changes are required. This adapter does not schedule notifications or play sound.

`LocalRecoveryDiagnostics` retains at most 32 fixed event codes in a private local
file. It records boot changes, wall drift exceeding one second, and unavailable
recovery. No IDs, timestamps, item names, balances, or raw exception details enter
the file. A failed log write cannot turn a committed settlement into failure.
Keep this operational log out of manual backups.

Validation includes native Android/iOS clock sampling tests, an iOS integration
test using the actual clock bridge and native SQLite reopen, fake-clock lifecycle
and failure tests, asynchronous compact-timer races, and real Dart subprocesses
terminated with SIGKILL after committed commands. The latter cover same-boot
wall edits, reboot estimates, paused relaunch, deadline completion, and duplicate
recovery with unchanged currency and bonus totals. They are synthetic recovery
tests; physical-device lock, reboot, system clock changes, and notification
acceptance remain separate device tests. The app composition task wires this
adapter into the complete native product; the foundation entry point remains a
preview until those screens and settings are connected.
