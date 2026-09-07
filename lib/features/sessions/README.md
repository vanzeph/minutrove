# Session experience

`SessionRoute.open` plugs into `HomeRoutes.openSession`. Keep one SQLite store,
clock, command coordinator and lifecycle owner above navigation:

```dart
final sessionRoute = SessionRoute(
  sessions: sessions,
  clock: clock,
  watchSession: (id) => watchSqliteSession(store, id),
  reconcile: lifecycle.reconcile,
  operationId: editing.operationId,
);
// HomeRoutes(..., openSession: sessionRoute.open)
```

Start `SessionLifecycle` and await initial recovery before exposing Home. Keep it
running while routes are closed, and dispose it before closing the store. The
route does not create another lifecycle or notification scheduler. Native app
composition supplies these dependencies; the default foundation preview remains
unchanged.

The large countdown and compact Home/Shop/Stats timer share `SessionClockView`.
They project bounded remaining time from fresh clock readings and committed
anchors, never from a count of UI ticks. Paused displays do not sample the clock.
Replaced revisions discard late asynchronous samples. Clock failures are visible;
zero displays Finishing until the repository commits completion.

The screen waits for recovery on entry/resume and before a new command, then
reads the current revision. Pause, resume and early end use repository commands.
Pending writes block repeated taps and route dismissal. An ambiguous failure
retains every request argument and operation ID; retry replays that command even
if the committed stream has already changed the displayed state. A stale revision
requires reviewing the current state and explicitly trying again.

`watchSqliteSession` reads the session, current item appearance, session-filtered
ledger earnings, fractional remainders and Award balance in one transaction.
Current name/icon/color edits appear immediately; duration and earning rates stay
frozen in the session snapshot. Displayed earnings add only the unsettled normal
accrual to committed session earnings (including already paid daily bonuses).
They retain fractional carry from previous runs and do not write a projection.
Future goal bonuses appear only after commitment. Timed Awards display elapsed
and remaining run time plus an independent budget when present. Purchases during
a run add to the pooled allowance without lengthening the current run.

Close/system Back leaves the session active and makes Home, Shop and Stats
available. Reopening the compact timer preserves pause state. Terminal committed
state dismisses only that session route and returns Home. Home also watches a
released slot, verifies its terminal record, and shows a dismissible saved-result
message; completion from another tab returns Home once, after foreground resume.
An unrelated modal draft is retained. Starting another timed item or submitting
an expense uses the same conflict dialog; the caller revalidates consent and the
existing repository command atomically settles the current session before the
next action. Cancel has no side effects.

The layout uses existing Nunito Sans, tokens, buttons and bundled icon assets.
The progress ring is a live Flutter progress control. At enlarged text the timer
uses a linear progress control so countdown text can wrap; all content scrolls
and actions remain at least 48 points/dp tall.

Validation:

```sh
flutter test test/features/session_experience_test.dart \
  test/features/compact_session_clock_test.dart
flutter test test/features/session_experience_test.dart \
  --dart-define=UI_EVIDENCE=true
bash tool/check.sh
```

The integration suite also exercises the route against native SQLite and the
native clock. Synthetic [UI evidence](../../../docs/ui-evidence/sessions/README.md)
is separate from physical-device VoiceOver/TalkBack, notification sound, lock or
reboot acceptance. Those remain downstream native product acceptance.
