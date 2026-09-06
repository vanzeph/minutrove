# Home navigation evidence

Synthetic Flutter widget renders using bundled Nunito Sans on Flutter 3.47.2 /
Dart 3.13.2. Captured 6 September 2026. These exercise `HomeShell` with the real
SQLite item/session repositories and atomic Home read model.

| Render | Coverage |
| --- | --- |
| [Home, 390 × 844](home-390.png) | Mixed Quest/Award group, same icon and color, wallet, explicit Configure and layout entry |
| [Home, 320 × 568, 200% text](home-320.png) | Natural-height items, wrapping group heading and scrollable content |
| [Active Home, 320 × 568, 200% text](home-active-320.png) | Persistent compact timer and navigation; Home content scrolls within the remaining space |
| [Active Shop slot, 390 × 844](shop-active-390.png) | Wallet and same global session remain visible after switching tabs |

The Shop content in this shell test is an injected route fixture, not evidence
of the separate redemption screen. The parameterless app still opens the
foundation preview; the native composition root injects HomeShell and the real
feature routes as described in `lib/features/home/README.md`.

Reproduce from the repository root:

```sh
flutter test test/features/home_shell_test.dart --dart-define=UI_EVIDENCE=true
```

The 14 Home tests also check delayed tap recognition, zero operation/ledger
changes on double tap, cancellation on navigation/configuration/disposal, actual
item-type routing, archived/purchased allowance filtering, paused-session
conflicts, committed exhaustion, persistent layout edits, read recovery, and
idempotent start retries. Android/iOS tap-target and label guidelines pass at
both sizes. Physical-device VoiceOver/TalkBack and native session lifecycle
acceptance are separate from these widget checks.
