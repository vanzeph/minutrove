# Shared UI

Import `core.dart` from features. The UI core accepts presentation values and
callbacks; it does not import repositories, persist edits, or run the economy.

- `TroveTokens.theme()` provides the bundled Nunito Sans typography, paper/ink
  colors, spacing, shapes and Material controls. `registerTroveAssetLicenses()`
  registers bundled notices with Flutter's standard license page.
- `ItemTile` accepts independent `TileKind`, `iconKey` and `ItemPalette`. Flutter's
  tap/double-tap gesture arena defers activation when a double tap is possible.
  Screen readers get activation and a custom Configure action; a visible
  Configure button supports keyboard and touch discovery. Feature callers own
  conflict handling and the actual command. `ItemTileGroup` wraps natural-height
  tiles rather than fixing a grid aspect ratio.
- `IconCatalog` has 75 stable selectable keys with case-insensitive multiword
  search, activity synonyms, and labels. Treat keys as opaque persisted strings;
  don't rename them to translated labels. Unknown keys render the bundled puzzle
  fallback without changing the caller's stored key. The catalog has no type or
  color restrictions. System navigation/currency symbols are separate.
- `showIconPicker` returns a selected key or null on cancel. `showItemColorPicker`
  returns an opaque RGB color or null on cancel. Its preset buttons and validated
  six-digit hex field preview the same shape for both item types. Neither writes
  caller state. `ItemPalette.custom` retains the chosen accent and uses a
  contrasting background when necessary; names and type labels always use ink.
- `showTroveDialog`/`TroveDialog` center a bounded, scrollable surface. Dialog
  insets follow the keyboard and safe area. Forms own their controllers and
  validation; awaiting the result allows cancellation without a commit.
  `TroveTextField` uses wrapping external labels for accessibility, and
  `TroveFormRow` stacks paired fields on narrow screens or at large text sizes.
  `TroveButton` wraps its label and grows above the minimum tap height.
- `WalletDisplay` and `CurrencyDisplay` format integer millionths without a
  floating-point conversion or display rounding. Coins and Gems remain distinct.
  Real-currency budgets are formatted by feature currency metadata, not these
  virtual-currency widgets.
- `TroveNavigationBar` exposes Home, Shop and Stats. `CompactSessionBar` accepts
  an already-formatted time and running/paused state; it is not a timer.

`ComponentGallery` is a synthetic development harness, available for explicit
embedding from a test/debug route. It does not seed data or change the app's
feature navigation. The app shell consumes the shared theme and navigation.

## Verification

Run `flutter test --reporter expanded`. To render the gallery and form at 390 px
and at 320 px with 200% text, run:

```sh
flutter test test/ui_core_test.dart --dart-define=UI_EVIDENCE=true
```

PNGs go into ignored `build/ui-evidence/`. These are synthetic widget renders,
not device screenshots. Tests also cover the gesture distinction, explicit
Configure, exact amount formatting, independent appearances, icon search,
invalid custom colors, keyboard avoidance and state retention. Native
VoiceOver/TalkBack and platform lifecycle tests remain feature/device acceptance.
