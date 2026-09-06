# Item configuration evidence

Synthetic Flutter widget renders on 6 September 2026 using the bundled Nunito
Sans font and Flutter 3.47.2 / Dart 3.13.2. `1.0x` uses a 390 × 844 logical-pixel
phone; `2.0x` uses 320 × 568 with 200% text. Keyboard renders reserve 220 logical
pixels for the keyboard. Long dialogs intentionally scroll; screenshots capture
one viewport, not the entire form. Award captures show the combined Award's
price/save section. Group captures show the layout entry and its scroll surface.

Reproduce with:

```sh
flutter test test/features --reporter expanded --dart-define=UI_EVIDENCE=true
```

The feature suite covers exact input and round trips, multiple Quests and all
three Award configurations at both phone sizes, cancellation and nested draft
retention, storage retry, duplicate-save exclusion, history races, stale edits,
archive/unarchive, actual SQLite goal effective dates, group/item ordering and
removal/reassignment. It includes tap-target/label checks and keyboard avoidance.
These are synthetic widget renders and agent visual inspection, not device
screenshots or claims of physical VoiceOver/TalkBack/native keyboard testing.
