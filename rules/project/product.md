# Product

FixDock is a macOS 14+ (Apple Silicon only) menu bar app for a repair bench,
written in Swift/SwiftUI/AppKit with no dependencies. It is an unofficial
GPL-3.0-or-later fork of vorssaint-utils. Each tool is an `AppFeature` the
person installs from the feature hub.

Source of truth:

- Tools and their order: `AppFeature` in `Sources/FixDock/Core/FeatureCatalog.swift`,
  pinned by `Tools/check-shell.py`.
- A tool's behaviour and owner decisions: its design doc in `docs/`.
- Upstream code: git history only, `git show 1cdbd59b:Sources/Vorssaint/<path>`.

Invariants:

- Bundle id `io.github.qaws81877.fixdock` (`.dev` for the developer build).
- English and Korean only; every string in both tables.
- Global shortcuts: the panel (Control-Option-Command-F) and, while the
  screenshot tool is installed, the capture overlay (Control-Option-Command-4)
  and full screen (Control-Option-Command-3), all in `HotkeyRole`. Any further
  global shortcut needs the owner first.
- One network endpoint: the update check against FixDock's own GitHub
  releases (`AppInfo.releaseFeedURL`, PRIVACY.md). No other endpoint, no
  upstream update feed, no analytics or telemetry.
- `LICENSE` byte-identical to upstream; `NOTICE` keeps the upstream credit and
  only gains entries (forks, bundled third-party assets with their license).
- No Vorssaint name, logo, bundle id, signing identity or domain
  (`TRADEMARKS.md`).
- App artwork is FixDock's own (GPL, stated in `NOTICE`). The committed
  `Resources/AppIcon.png` and the template menu bar mark
  `Resources/Icons/fixdock-mark.svg` are the sources; the owner chose not to
  keep a generator script in the repo. Changing the logo needs the owner first.

Not goals: App Store or sandboxing, an Intel build, a second module or
source directory (`build.sh` compiles `Sources/FixDock/` only).
