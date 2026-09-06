# Application boundaries

`main.dart` starts `MinutroveApp`; `ui/core/app_shell.dart` provides the synthetic
Home, Shop, and Stats smoke surface. It does not start sessions or change balances.

- `domain/`: pure Dart entities, commands, and ports; no Flutter widgets,
  database plugins, or OS dependencies.
- `data/`: persistence adapters and transactions implementing domain ports.
- `platform/`: OS, clock, notifications, and file integrations.
- `ui/core/`: shared application shell, theme, and presentation components.
- `features/`: Home, items, sessions, Shop, Stats, and settings presentation.

Empty directories are intentional extension points. Introduce dependencies with
the feature that needs them, preserving a single root Flutter package. Feature
views call commands or observe read models; business rules belong in `domain/`.
