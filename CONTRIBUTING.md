# Contributing

FixDock is a personal unofficial fork of vorssaint-utils (GPL-3.0-or-later).

- Keep the LICENSE file unchanged.
- Keep upstream copyright headers. Add a FixDock copyright line when you modify a file.
- Do not reintroduce the Vorssaint name, icon, signing identity, update feed, or network endpoints. FixDock's one network use is its own update check (PRIVACY.md); another one needs the owner first. See TRADEMARKS.md and NOTICE.
- English and Korean only, until someone deliberately adds another language to both string tables.
- Feature modules come back in the order listed in `AppFeature` in `Sources/FixDock/Core/FeatureCatalog.swift`.
- Build with `./build.sh` on a Mac. This repository's CI only runs static checks.

Issues belong on this repository. Do not send FixDock bugs to the upstream maintainers.
