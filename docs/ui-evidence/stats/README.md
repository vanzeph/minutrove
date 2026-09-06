# Stats UI evidence

Synthetic Flutter widget renders, using the bundled Nunito Sans font and the
pinned Flutter 3.47.2 / Dart 3.13.2 toolchain. No personal activity data is used.

- `stats-390.png`: 390 × 844, standard text, filters and bar charts.
- `stats-lines-390.png`: 390 × 844, line charts with period controls.
- `stats-daily-320.png`: 320 × 568, 200% text, scrolled to the Daily chart.
  Vertical scrolling reaches the remaining controls; the plot scrolls
  horizontally at this text scale to retain readable axes.
- `stats-budget-usd.png`: USD budget measure; JPY is independently tested.

Generate with:

```sh
flutter test --no-pub test/features/stats_screen_test.dart \
  --dart-define=UI_EVIDENCE=true
```

The tests also cover every period's numeric expansion at both sizes, labeled
minimum-size controls, a 5,000-item archived catalog, stale responses, filters,
calendar navigation, and error recovery. SQLite integration verifies the four
readouts against settled session/ledger totals and confirms that HomeShell
navigation preserves its active session and performs no economic write.

These are agent-reviewed widget renders. They are not physical-device
VoiceOver/TalkBack sign-off or evidence of final native app composition; those
belong to whole-product integration acceptance.
