# Owned Award use evidence

Synthetic Flutter widget renders captured 6 September 2026 with the pinned
Flutter 3.47.2 / Dart 3.13.2 toolchain and bundled Nunito Sans. These exercise
HomeShell and AwardExpenseRoute against real SQLite repositories.

| Render | Coverage |
| --- | --- |
| [Combined Award](combined.png) | 390 × 844; live independent allowances, time/expense choice, Configure and Cancel |
| [Actual expense](expense-1.0.png) | 320 × 640; USD 35.00 minus 12.50 previews USD 22.50 |
| [Large expense text](expense-2.0.png) | 320 × 640, 200% text; naturally wrapping content in one scrollable centered dialog |
| [Keyboard and actions](expense-keyboard-1.0.png) | 260-pixel keyboard inset with reachable Record and Cancel |
| [Keyboard and large actions](expense-keyboard-2.0.png) | 200% text; scrolled action remains reachable above keyboard inset |

Reproduce:

```sh
flutter test test/features/award_expense_test.dart --dart-define=UI_EVIDENCE=true
```

The 14 new real-SQLite widget tests cover actual expense/receipt, exact budget
exhaustion and history retention, malformed/nonpositive/over-budget values with
editable input, cancel and double-tap side-effect prevention, combined time and
budget settlement, replacement-session consent, lost committed acknowledgement
with idempotent retry, repeated-submit/close protection, stale revision review,
archived balances, read failure recovery, live combined allowances and Configure,
new session conflicts, and Android/iOS tap-target and label guidelines at both
text scales. The existing 14 Home tests additionally cover direct timed starts,
early/paused session routing, and committed timed exhaustion.

The complete local repository gate passed 227 tests, format, and analysis.
These are widget/accessibility guideline checks; physical-device screen readers,
notifications and background lifecycle are downstream acceptance. The native
product-loop composition task injects this expense route into the app's shared
HomeShell. This feature does not change the parameterless foundation preview.
