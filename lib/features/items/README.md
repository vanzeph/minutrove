# Item configuration and layout

Import `items.dart` and supply `ItemEditing` from the app composition root:

```dart
final editing = ItemEditing(
  repository: itemRepository,
  currencies: pinnedCurrencyMetadata,
  readFacts: sqliteItemEditFacts(store),
);
await showItemEditor(context: context, editing: editing); // New Quest or Award
await showItemEditor(context: context, editing: editing, item: selectedItem);
await showGroupManager(context: context, editing: editing);
```

The repository and facts reader must share the app's store. The currency metadata
must be the same pinned metadata used to open that store. The feature does not
pick a currency set, reporting timezone, or sample economics. `newUuid` defaults
to random UUID v4 and can be injected for deterministic tests.

Home/Shop composition can call these entry points from Create, Configure, and
Edit layout actions. Item/group streams are authoritative for refreshing the
caller, including when the user closes a saved receipt using its close button.
`Done` on the saved receipt also returns the committed item. The shell and native
session navigation are composed separately from this feature.

The editor supports Quest countdown and rate units, daily goals and bonuses,
whole Award packs, both virtual prices, time/budget/combined grants, ISO currency
precision, independent icons and custom colors, group assignment, archive and
unarchive. Changing units reinterprets the entered number; the visible unit is
always part of its meaning. Existing rates open per hour to preserve every
stored millionth without rounding. All numeric input uses domain parsers.

Draft controllers survive type/allowance changes, nested picker cancellation,
keyboard changes and failed commands. Cancel has no write. Saving locks dismissal
and repeated submissions; retrying an unchanged failed save reuses its operation
ID. Stale edits require an explicit discard-and-reload action. History and active
session facts guide controls, while repository validation still rejects races.
A saved Quest receipt reads the actual latest persisted daily-goal revision and
reporting zone; failed date reads retry the lookup without repeating the save.

Layout mode saves each action immediately. Group removal atomically reassigns
all items, including archived ones, to Ungrouped. Reorder uses the existing
revision-checked save commands in sequence; if a command fails, it stops, retains
committed order changes, and displays the current live order with an explicit
partial-save notice. Reordering never modifies item configuration or allowances.
Archived items can be shown, configured, and unarchived here.

Run `flutter test test/features --reporter expanded`. For synthetic widget
renders at 390 × 844 and 320 × 568 with 200% text, append
`--dart-define=UI_EVIDENCE=true`. These tests exercise native Flutter controls,
not physical-device keyboard or VoiceOver/TalkBack behavior. Device acceptance
and full Home/Shop integration remain part of their respective delivery work.
