# Contributing to Minutrove

The repository contains the shared Flutter app foundation for iOS and Android.
Follow the pinned setup and validation commands in [README.md](README.md).

Before starting substantial implementation, agree its behavior and scope through
the product design process or an issue. Work assigned under an approved design
can proceed within that boundary.

For pull requests:

- Explain the user-visible problem and resulting behavior.
- Include relevant validation, or explain why a change cannot yet be run.
- Keep platform-specific code separate from shared product rules.
- Preserve copyright and license notices. Identify the source and license of any third-party code, icons, fonts, or audio.
- Do not commit credentials, signing keys, personal activity data, or local machine configuration.

## Disclosure review

Minutrove's public promises are auditable from source, and changes must keep
them true. In the same pull request:

- **New or changed OS permission**: justify it in the manifest, update the
  permission table in [docs/privacy.md](docs/privacy.md), and keep it scoped
  to what the feature needs.
- **New dependency**: check AGPL-3.0-only compatibility, pin the exact version
  in `pubspec.yaml`/`pubspec.lock`, and add or update its entry in
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). A hosted service,
  analytics, or network-capable dependency needs design review first.
- **New asset** (font, icon, audio, image): record its upstream source,
  license file and SHA-256 in [assets/provenance.json](assets/provenance.json),
  keep the license text under `assets/licenses/` or `third_party/`, and
  register it for the in-app notices if it ships in the app.
- **Network, diagnostics or backup behavior**: the app makes no network
  requests, writes only fixed-code local diagnostics, and discloses that
  backups are unencrypted. Keep [docs/privacy.md](docs/privacy.md) and
  [docs/backup-format.md](docs/backup-format.md) accurate when these change.
- **Test data and evidence**: keep fixtures synthetic. Never commit personal
  activity data, real device identifiers, or private design documents.

CI has no signing secrets; do not add any. Builds and notices stay
reproducible from a clean checkout with the pinned toolchain.

Original contributions are made under the repository's AGPL-3.0-only license.
