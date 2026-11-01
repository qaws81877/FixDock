# Engineering

Change directly:

- Code under `Sources/FixDock/`, strings in both tables, `Tools/check-shell.py`
  rules that a new module requires (in the same change).
- A tool's design doc in `docs/` when its behaviour changes.

Ask the owner first:

- Anything that deletes, moves or overwrites user files, and the guard for it.
- A new permission, a second global shortcut, a network call other than
  the update check, or a new bundled third-party asset (and its license).
- Scope cuts from upstream that change what a tool does for the person.
- Commits, pushes, PRs and merges, unless the owner asked for them.
- Creating a public repository. Auto mode blocks it even when asked; hand
  the owner the exact `! gh repo create …` line instead of working around it.

Docs:

- One design doc per tool in `docs/`, updated when the owner decides something.
- `docs/` is local (gitignored): design docs, handoffs and `docs/PROGRESS.md`
  (phase, commit, gate result, pending owner checks).

Git:

- A release ends with the Homebrew tap: in qaws81877/homebrew-tap, set
  `version` and `sha256` (the release asset's digest) in
  `Casks/fixdock.rb`, then `brew audit --cask --online --strict`.
- Publish with one `gh release create v<version> build/release/FixDock-<version>.zip --target <full SHA>`;
  a short SHA is refused ("Release.target_commitish is invalid").
- Merge PRs with a merge commit only, never squash or rebase. `main` must
  keep the upstream import merge `7336fd32` reachable.
- A new `git worktree` has none of the local files. Copy `CLAUDE.md`,
  `.claude/` and the `docs/` the task needs into it (`rules/` is tracked),
  and bring changed docs back before removing the worktree.
- When another session may be editing the main working tree, build,
  verify and release from `git worktree add --detach <dir> origin/main`
  (or a branch in its own worktree); building the live tree failed with
  "input file … was modified during the build".
- Stages built in parallel branch from one commit that already holds the
  shared contract: the shared files, a stub for the seam between them,
  and string block markers before `versionFormat` (one per branch, with
  lines between) so each branch adds strings in its own block.

Clipboard:

- Every write to the general pasteboard goes through
  `GeneralPasteboardAccess`, calls `declareAppSource()` after
  `clearContents()`, and passes the new `changeCount` to
  `URLCleanerService.shared.ignoreChanges(upTo:)` on the main thread.

Bundle:

- `build.sh` copies only `Resources/*.lproj` and `Resources/Icons` into the
  app. A new resource folder needs its own copy line there. Without it, the
  app silently uses fallbacks.
- Bump the version by editing the two `Resources/Info.plist` values as text.
  `PlistBuddy -c Set` rewrites the file and reorders its keys.

Platform quirks:

- A closed `NSPopover` keeps its SwiftUI views, so `onDisappear` never fires,
  and the Settings window is reused (`isReleasedWhenClosed = false`). Track
  visibility with `NSPopoverDelegate` and `windowWillClose`.
- On macOS 27, `List(selection:)` in the Settings sidebar hides Section
  headers, and a `Button` in that `List` gets no clicks. Use a plain `List`
  with `onTapGesture` rows.
- `standardizedFileURL` and `resolvingSymlinksInPath` drop a `/private`
  prefix. Compare real paths with `realpath(3)`, never with those.
- A bundle swapped in by rename(2) has no quarantine flag and never gets
  Gatekeeper's first-launch check, so the updater checks the signature and
  notarization itself. The installed app is swapped only by `Relauncher`
  (`RENAME_SWAP`, pinned by `check-shell.py`), and removals under the update
  workspace only by `UpdateWorkspace.sweep`.
  Any change to `Relauncher` keeps one rule: nothing stays at the install
  path unless it passed the identity check there; otherwise it is moved
  aside, never deleted, and nothing is opened. Judge security-review
  findings against that rule instead of flipping between "restore" and
  "keep".
- ScreenCaptureKit: leave FixDock out by application
  (`SCContentFilter(display:excludingApplications:exceptingWindows:)`),
  not by a window list. `SCShareableContent` read right after a panel is
  shown does not list it yet, and a list never covers later windows.
- `CGImage.cropping(to:)` shares the source image's pixels. A crop kept
  past the frame it came from (strips, thumbnails) is copied into its own
  bitmap first; kept crops of stream frames took one capture to 1.2 GB.
- `AVAssetWriter.cancelWriting()` deletes its output file. Point a writer
  only at an app-owned folder or a staged sibling it created, never
  straight at a file in the person's folder.
