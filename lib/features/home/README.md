# Home and navigation composition

`HomeShell` is the live Home feature and shared Home/Shop/Stats navigation shell.
Pass it as `MinutroveApp(home: homeShell)` from the native composition root.
The parameterless app retains the explicitly labeled foundation preview until
native startup and the remaining feature screens are composed.

```dart
final homeShell = HomeShell(
  watchHome: () => watchSqliteHome(store),
  editing: editing,
  sessions: sessions,
  clock: clock,
  routes: HomeRoutes(
    shop: buildShopContent,
    stats: buildStatsContent,
    openSession: openSession,
    openExpense: openExpense,
    openSettings: openSettings,
  ),
);
```

Use the same live `SqliteStore`, `ItemRepository`, `SessionRepository`, clock,
pinned currency metadata, and item facts reader throughout the app. Home does
not create a second store or choose a reporting timezone. `watchSqliteHome`
reads definitions, groups, allowances, wallet, and active session together in one
transaction and publishes a new snapshot after committed changes. Stream errors
show a retry action and disable launchers instead of fabricating an empty wallet.

Shop and Stats builders provide page content, without another navigation bar or
wallet header. Both retain widget state across tab changes. A session route takes
a `SessionId` and a `returnHome` callback; the screen observes the app's shared
session repository, dismisses itself and calls that callback on completion or
early end. Opening the compact slot or selecting the current Quest resumes its
screen without creating another operation or implicitly unpausing it.

The expense route takes the latest displayed `Item`, `AwardBalance`, and explicit
`SessionConflictChoice`. Opening or cancelling the form must change nothing.
Pass the balance revision and conflict choice to the transactional expense
command on submit. Recheck the active session if it changed while the form was
open; do not reuse consent to end a different session. Combined Awards always
let users choose time or expense, with an exhausted dimension disabled. This
also applies while their time session is active.

The compact timer projects remaining time from the injected clock and committed
session checkpoint, excluding paused time. It never settles money, schedules
notifications, or declares completion on a UI tick. Native lifecycle/session
composition owns checkpoints, recovery, settlement and returning Home at zero;
Home displays `Finishing` at zero until that committed result arrives.

Home shows unarchived Quests and one tile for each Award with any remaining
allowance, including archived Awards. Sorting follows saved group/item order
with stable identity tie breaks. Ungrouped is not persisted as a synthetic group.
The shared item editor and layout manager perform creation, configuration,
reorder, moving and archive operations; their committed streams refresh Home.

The shared `ItemTile` uses Flutter's competing tap and double-tap recognizers:
`onTap` waits for double-tap resolution. Home invalidates pending recognition on
navigation, configuration, modal routing, stream replacement and read failure.
Screen readers and keyboards have an explicit Configure button/action. Starts
use operation IDs and revision checks; a retry of a failed start keeps its ID.

Run the real SQLite interaction tests:

```sh
flutter test test/features/home_shell_test.dart --reporter expanded
flutter test test/features/home_shell_test.dart --dart-define=UI_EVIDENCE=true
```

Screenshots in `build/ui-evidence` use only synthetic activity. Widget tests are
not physical-device VoiceOver/TalkBack, background clock, or notification tests.

The compact timer awaits fresh `Clock.now()` samples and ignores results from a
replaced session/revision or a disposed widget. An unavailable sample shows
`Time unavailable` until a later sample succeeds; paused display uses committed
progress. It never posts ledger changes. Native startup/resume integration uses
[SessionLifecycle](../../platform/sessions/README.md) before commands rely on the
current session revision.
