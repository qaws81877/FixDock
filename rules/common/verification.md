# Verification

There is no test target (`Tests/` is forbidden by `Tools/check-shell.py`).

Gates, in order, before calling a change done:

1. `python3 Tools/check-shell.py` (the only thing CI runs).
2. No warnings. `swift build` is incremental and its intermediates live
   under `.build/out/Intermediates.noindex`, so a clean-looking rebuild can
   compile nothing. The proof is a full typecheck with `build.sh`'s flags:
   `swiftc -typecheck -swift-version 5 -target arm64-apple-macosx14.0 -sdk <build.sh SDK> <its compat flags> <every Sources/FixDock file>`.
3. `./build.sh`, then launch `build/stage/FixDock.app` for anything the owner
   will try in the app.

- `check-shell.py` also scans the local, gitignored `docs/` files. A web
  address written there (even inside backticks in a brief or handoff) fails
  the gate; describe it in words.

- `swift build` does not refresh the app that is running. Before any live
  test, rebuild, quit FixDock and open the new bundle. A
  `./build.sh --dev` bundle alone is not enough: rebuild and relaunch the
  copy the owner runs (check its path with `ps`). Since 2026-10-31 that is
  `/Applications/FixDock.app` (`./build.sh --install`).
- An agent shell may not have `FIXDOCK_CODESIGN_IDENTITY`. Pass it on the
  command line, for example `FIXDOCK_CODESIGN_IDENTITY="<SHA-1>" ./build.sh`.
  Do not edit shell profiles. An ad-hoc build resets Accessibility and other
  grants on every rebuild.
- A developer build with AirDrop auto-zip on blocks at launch on the
  Downloads permission prompt. Start scripted dev runs with
  `-airdropAutoZipFolderOverride <scratch dir>`.
- SourceKit "Cannot find … in scope" right after an edit is often stale.
  The result of `swift build` decides.

Proof:

- Logic with risk (deletion, compression, parsing) is shown with a small
  harness compiled from the source files themselves, on scratch data.
  `xcrun swiftc -swift-version 5 -o <out> <Sources files> <stubs>.swift <dir>/main.swift`.
  Top-level statements are allowed only in a file named `main.swift`. Stub
  `AppFeature`, `Permissions` or `DefaultsKey` instead of pulling in the app.
- Self-update has three harnesses, all on scratch data: the pure policy
  (`Core/UpdatePolicy.swift` alone); the verifier and transport on the real
  release zip, tampered zips and a local feed (`Tools/make-local-feed.sh`,
  a build with the local-feed compile flag); and the helper protocol on
  developer bundles copied to scratch (swap, rollback, guards, sweep
  protection, plain relaunch). Ad-hoc bundles reach only the guards: every
  swap, rollback and eviction case needs a Developer ID-signed old bundle
  and a notarized, stapled newer one. A real update of the owner's app
  needs the owner's click.
- The cask's `uninstall quit:` quits a running FixDock, so a
  `brew uninstall` test also stops the owner's app. Reopen it afterwards.
- A test release made with `FIXDOCK_VERSION` and `Tools/notarize.sh` is
  moved out of `build/release/` right away and never uploaded. Left there,
  it blocks notarizing the real version and can be published by mistake.
- To check SwiftUI states as PNGs, render with `NSHostingView` in an
  offscreen key window (`cacheDisplay(in:to:)`). `ImageRenderer` draws
  `ProgressView` as a placeholder and leaves `ScrollView` content blank.
- Pixel checks in a harness: a `CGContext`'s memory starts at the image's
  top row, and `CGImage.cropping(to:)` counts y from the top too.
- Behaviour on the Mac (permissions, menu bar, AirDrop, Finder, real files)
  counts as verified only after the owner runs the numbered test list. Say
  plainly when that has not happened yet.
