# Session UI evidence

Synthetic Flutter renders of the implemented session feature. Values and names
are fixtures, not user activity or product defaults. All images are generated
from `test/features/session_experience_test.dart` with `UI_EVIDENCE=true`.

- `session-running-390.png`: dedicated running timer and earnings.
- `session-paused-390.png`: paused countdown and Resume/End controls.
- `session-running-320.png`: 320 × 568 phone at 200% text, wrapping item name.
- `session-paused-320.png`: paused state at enlarged text.
- `session-paused-controls-320.png`: scroll position exposing enlarged actions.

The screenshot review checks token/icon reuse, countdown and control legibility,
wrapping, and reachable scrolling. Widget tests validate platform tap-target
sizes and labels. Physical-device assistive technology and background behavior
are not established by these images.

Regenerate with the repository's pinned Flutter SDK:

```sh
flutter test test/features/session_experience_test.dart \
  --dart-define=UI_EVIDENCE=true
```

Outputs are in `build/ui-evidence/`; copy only the listed synthetic images here.
