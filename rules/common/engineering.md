# Engineering

Change directly:

- Code under `Sources/FixDock/`, strings in both tables, `Tools/check-shell.py`
  rules that a new module requires (in the same change).
- A tool's design doc in `docs/` when its behaviour changes.

Ask the owner first:

- Anything that deletes, moves or overwrites user files, and the guard for it.
- A new permission, a second global shortcut, a network call other than
  the update check and the feedback relay, a change to what feedback
  sends, or a new bundled third-party asset (and its license).
- Deploying the feedback relay or changing its secrets (the owner runs
  `wrangler`; its login and `secret put` need a TTY).
- Scope cuts from upstream that change what a tool does for the person.
- Commits, pushes, PRs and merges, unless the owner asked for them.
- Creating a public repository.
- When auto mode denies a git or gh action the owner asked for (its
  verdicts vary by context: on 2026-11-01 one session saw `gh pr merge`
  denied and branch deletes pass, another the reverse), hand the owner the
  exact `! …` line, one `!` command per message (a second `!` pasted on
  the next line is read by the shell as negation and the command after
  `&&` never runs).

Docs:

- One design doc per tool in `docs/`, updated when the owner decides something.
- `docs/` is local (gitignored): design docs, handoffs and `docs/PROGRESS.md`
  (phase, commit, gate result, pending owner checks).

Git:

- A release ends with the Homebrew tap: in qaws81877/homebrew-tap, set
  `version` and `sha256` (the release asset's digest) in
  `Casks/fixdock.rb`, then `brew audit --cask --online --strict`.
- Publish with one `gh release create v<version> build/release/FixDock-<version>.zip build/release/FixDock-<version>.dmg --target <full SHA>`
  (the DMG from `Tools/make-dmg.sh` after `Tools/notarize.sh`, owner 2026-11-05;
  the updater reads only the zip). A short SHA is refused ("Release.target_commitish is invalid").
- Stacked PRs: retarget the child with `gh pr edit <N> --base main` before
  merging its base with `--delete-branch`; deleting the base through the
  API closes the child instead of retargeting it.
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
- secret-scan on a branch with no upstream scans the whole history, the
  upstream import included, and flags its old test strings. Before the
  first push, scan with `git branch --set-upstream-to=origin/main`, then
  `git branch --unset-upstream`.

Clipboard:

- Every write to the general pasteboard goes through
  `GeneralPasteboardAccess`, calls `declareAppSource()` after
  `clearContents()`, and passes the new `changeCount` to
  `URLCleanerService.shared.ignoreChanges(upTo:)` on the main thread.
  That call also tells clipboard history, so no writer sets a watermark
  directly (`URLCleanerService.copy()` did until 2026-11-04).

Bundle:

- `build.sh` copies only `Resources/*.lproj`, `Resources/Icons` and
  `Resources/Sounds` into the app. A new resource folder needs its own copy
  line there. Without it, the app silently uses fallbacks.
- `check-shell.py` scans every file under `Resources/`, binaries included.
  Media converted from a tagged source carries its metadata (an MP3's
  comment had two `https://` links) and fails the URL check. Convert
  with `ffmpeg -map_metadata -1` and credit the source in `NOTICE`.
- Bump the version by editing the two `Resources/Info.plist` values as text.
  `PlistBuddy -c Set` rewrites the file and reorders its keys.

Platform quirks:

- Carbon `RegisterEventHotKey` returns noErr in every process that registers
  the same combination, and each press reaches all of them (two holders and
  FixDock all got one press, 2026-11-04). `HotkeyManager.failedRoles` only
  reports a refused registration, never a clash with another app.
- While any process holds Secure Event Input, session event taps get no
  keys: quit protection and snippets both go quiet with no warning
  (confirmed live). `kCGSSessionSecureInputPID` names the app that was
  frontmost when it was enabled, not the enabler. For "works sometimes"
  reports, read the `keyTaps` log or the General › Feedback report first.
- A `CGImage` keeps its decoded pixels once drawn or scanned by Vision,
  even when read with `kCGImageSourceShouldCache: false`, and an ordered-out
  window keeps its window-server backing store (measured with `footprint`:
  20 hidden pins, 158 MB Image IO and 151 MB unmapped). Hidden items hold
  the PNG and decode on read, and keep no window.

- A service's `syncWithPreferences` also runs from timers (the fast switch's
  1 s repair, permission polls) and from its system layer's callbacks. Put
  cancels and resets there only on a change of value, and once an exit
  restore starts, nothing may re-apply.

- A closed `NSPopover` keeps its SwiftUI views, so `onDisappear` never fires,
  and the Settings window is reused (`isReleasedWhenClosed = false`). Track
  visibility with `NSPopoverDelegate` and `windowWillClose`.
- On macOS 27, `List(selection:)` in the Settings sidebar hides Section
  headers, and a `Button` in that `List` gets no clicks. Use a plain `List`
  with `onTapGesture` rows.
- A SwiftUI window hosted by `NSHostingController` (Settings, `SettingsWindow`):
  with `.fullSizeContentView` a `.navigation` toolbar group sits past the
  sidebar instead of next to the traffic lights, and `navigationTitle` never
  reaches the window (`host.title` stays nil). Leave full size content off and
  set `window.title` yourself.
- The Settings sidebar `List` (an `NSOutlineView`) gets its rows on the run
  loop turn after layout, on screen or not (2026-11-08: 0 rows right after
  `layoutSubtreeIfNeeded` on a hidden window, 25 one turn later);
  `displayIfNeeded` does not fill it sooner. Measure on that turn, then show
  (`SettingsWindow.showFittingSidebar`).
- `standardizedFileURL` and `resolvingSymlinksInPath` drop a `/private`
  prefix. Compare real paths with `realpath(3)`, never with those.
- A bundle swapped in by rename(2) has no quarantine flag and never gets
  Gatekeeper's first-launch check, so the updater checks the signature and
  notarization itself. The installed app is swapped only by `Relauncher`
  (`RENAME_SWAP`, pinned by `check-shell.py`) and, for a first install from
  a disk image, by `InstallMover` (owner decision 2026-11-05). `InstallMover`
  offers only for a copy signed with the release's Developer ID, moves the
  existing copy to the Trash (never deletes it), checks the new copy before
  clearing quarantine and again at the install path, and puts the old copy
  back on any failure. Removals under the update workspace only by
  `UpdateWorkspace.sweep`.
  Any change to `Relauncher` or `InstallMover` keeps one rule: nothing stays at the install
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
