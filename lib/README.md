# Application boundaries

`main.dart` starts `MinutroveStartup` (in `app_startup.dart`), which opens the
local store, wires the real clock, notification, chime, and backup adapters,
recovers the persisted session, gates first-run onboarding, and builds the
`HomeShell` route graph. A validated restore rebuilds the whole graph over the
reopened database.

- `domain/`: pure Dart entities, commands, and ports; no Flutter widgets,
  database plugins, or OS dependencies.
- `data/`: persistence adapters and transactions implementing domain ports.
- `platform/`: OS, clock, notifications, and file integrations.
- `ui/core/`: shared application shell, theme, and presentation components.
- `features/`: Home, items, sessions, Shop, Stats, and settings presentation.

Empty directories are intentional extension points. Introduce dependencies with
the feature that needs them, preserving a single root Flutter package. Feature
views call commands or observe read models; business rules belong in `domain/`.
