# Reward Shop UI evidence

Synthetic SQLite fixtures rendered by `test/features/shop_test.dart` with
`--dart-define=UI_EVIDENCE=true`. The 390×844 captures use normal text; 320×640
captures use 200% text. Keyboard captures add a 220 logical-pixel keyboard inset
and scroll to the reachable purchase/cancel actions. No personal data or private
design content is included.

The catalog is captured as page content; the full Home shell integration test
separately verifies the shared wallet and single pooled Award tile after purchase.
The dialog uses bundled Nunito Sans, original icons and shared Flutter controls.

| State | Normal text | Large text |
| --- | --- | --- |
| Catalog | [390×844](shop-390.png) | [320×640](shop-320.png) |
| Quantity preview | [390×844](redeem-390.png) | [320×640](redeem-320.png) |
| Keyboard and actions | [390×844](redeem-keyboard-390.png) | [320×640](redeem-keyboard-320.png) |

The same suite checks synchronized min/max controls, input rejection, joint-price
shortages, cancellation without writes, pooled balances, duplicate taps, stale
quote and wallet races, lost post-commit responses, active sessions, archive
visibility, read recovery, checked arithmetic, labeled tap targets and keyboard
cancellation. These renders are agent visual review, not separate human design
approval or physical-device accessibility evidence.
