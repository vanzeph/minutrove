# Shared-component visual evidence

Synthetic Flutter widget renders, captured 6 September 2026 with the pinned
Flutter 3.47.2 / Dart 3.13.2 toolchain. These are component review fixtures, not
physical-device screenshots or completed feature journeys.

| Render | Conditions |
| --- | --- |
| [Gallery](gallery-1.0x.png) | 390 × 844; bundled Nunito Sans; same Gamepad/plum appearance across Quest and Award; exact wallet amount. |
| [Centered form](form-1.0x.png) | 390 × 844; wrapping external field labels and centered surface. |
| [Scrolled large-text gallery](gallery-scrolled-2.0x.png) | 320 × 568, 200% text; natural-height tiles, readable explicit types and Configure controls. |
| [Large-text form with keyboard inset](form-keyboard-2.0x.png) | 320 × 568, 200% text, 220 px keyboard inset; scrolled action remains above keyboard. |

Regenerate with `flutter test test/ui_core_test.dart --dart-define=UI_EVIDENCE=true`.
Raw renders are written to ignored `build/ui-evidence/`. Agent review confirmed
readable controls, asset fidelity, independent appearances, normal centered form
layout and scrollable enlarged layouts. Tests additionally verify 48 px/labeled
tap targets, deferred single vs double tap, retained form input, exact integer
amount formatting, searchable asset keys, valid color input and icon contrast.
Native screen-reader behavior and complete feature journeys remain downstream
acceptance work.
