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

Docs:

- One design doc per tool in `docs/`, updated when the owner decides something.
- `docs/` is local (gitignored): design docs, handoffs and `docs/PROGRESS.md`
  (phase, commit, gate result, pending owner checks).

Git:

- Merge PRs with a merge commit only, never squash or rebase. `main` must
  keep the upstream import merge `7336fd32` reachable.
- A new `git worktree` has none of the local files. Copy `CLAUDE.md`,
  `.claude/` and the `docs/` the task needs into it (`rules/` is tracked),
  and bring changed docs back before removing the worktree.
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
- `AVAssetWriter.cancelWriting()` deletes its output file. Point a writer
  only at an app-owned folder or a staged sibling it created, never
  straight at a file in the person's folder.
