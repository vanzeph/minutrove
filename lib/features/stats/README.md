# Stats

`StatsScreen` is the scrolling `HomeRoutes.stats` body. It shares the shell's
wallet and compact session slot and performs no session or economic command.
Compose the adapter once with the same store and reporting calendar used by the
rest of the app:

```dart
final stats = SqliteStatsSource(store: store, calendar: calendar);
final routes = HomeRoutes(
  stats: (_) => StatsScreen(source: stats),
  // Supply the other feature routes from the native composition root.
);
```

The feature is wired in HomeShell integration tests. The production native
composition task supplies this route; the parameterless foundation preview
remains a separate synthetic surface until that task integrates the app.

All four periods load in one SQLite read transaction. Updates replace the whole
snapshot, and late responses cannot overwrite a later selection. Refresh and
foreground resume reload committed activity. While a new snapshot loads, the
previous cards retain their layout space but hide their values and interactions.
Reading Stats does not checkpoint an active timer.

Item search includes archived definitions. Metrics use the same type/dimension
compatibility as the domain query, and budget choices retain ISO currency and
minor-unit precision. No unlike units are combined. Currency values and totals
use integer/BigInt formatting; time labels round to 0.001 minute and disclose
smaller nonzero values as `<0.001`. Only plot positions use floating point.

Each card keeps its own selected date, previous/next/current controls, and a date
picker supporting direct entry for long histories. Current means the saved
reporting timezone's date. Civil bucket labels preserve frozen event assignments
across travel; repeated DST hours combine and missing hours stay zero, matching
the repository. Current periods follow date changes; browsed history stays put.

Bars and lines have numeric axes, a readable total, and expandable values for
every bucket. At large text, controls stack and plots can scroll horizontally.
Category and metric choices include explanations for disabled combinations;
storage errors show Retry instead of a false zero-activity chart.

Validation: `flutter test test/features/stats_screen_test.dart
test/features/stats_source_test.dart`. Set `--dart-define=UI_EVIDENCE=true` to
capture synthetic widget renders in `build/ui-evidence`. Device-level
VoiceOver/TalkBack and final native composition remain whole-product acceptance.
