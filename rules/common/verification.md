# Verification

There is no test target (`Tests/` is forbidden by `Tools/check-shell.py`).

Gates, in order, before calling a change done:

1. `python3 Tools/check-shell.py` (the only thing CI runs).
2. `swift build` with no warnings.
3. `./build.sh`, then launch `build/stage/FixDock.app` for anything the owner
   will try in the app.

- `check-shell.py` also scans the local, gitignored `docs/` files. A web
  address written there (even inside backticks in a brief or handoff) fails
  the gate; describe it in words.

- `swift build` does not refresh the app that is running. Before any live
  test, run `./build.sh`, quit FixDock and open the new bundle.
- An agent shell may not have `FIXDOCK_CODESIGN_IDENTITY`. Pass it on the
  command line, for example `FIXDOCK_CODESIGN_IDENTITY="<SHA-1>" ./build.sh`.
  Do not edit shell profiles. An ad-hoc build resets Accessibility and other
  grants on every rebuild.
- SourceKit "Cannot find … in scope" right after an edit is often stale.
  The result of `swift build` decides.

Proof:

- Logic with risk (deletion, compression, parsing) is shown with a small
  harness compiled from the source files themselves, on scratch data.
  `xcrun swiftc -swift-version 5 -o <out> <Sources files> <stubs>.swift <dir>/main.swift`.
  Top-level statements are allowed only in a file named `main.swift`. Stub
  `AppFeature`, `Permissions` or `DefaultsKey` instead of pulling in the app.
- Pixel checks in a harness: a `CGContext`'s memory starts at the image's
  top row, and `CGImage.cropping(to:)` counts y from the top too.
- Behaviour on the Mac (permissions, menu bar, AirDrop, Finder, real files)
  counts as verified only after the owner runs the numbered test list. Say
  plainly when that has not happened yet.
