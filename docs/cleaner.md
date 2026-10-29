# Cleaner (7.5) design

Status: agreed with the owner 2026-10-29; implemented in feat/cleaner.

## Sources compared

- Upstream vorssaint-utils Cleaner at `1cdbd59b` (`Services/Cleaner/*`,
  `UI/Cleaner/CleanerView.swift`): scan, per-item review, move to Trash.
- tw93/mole (GPL-3.0): path lists and safety rules only. Its flow (no
  review, every category on, `rm -rf`) is not copied. Path lists informed by
  it are credited in the source file that holds them and in `NOTICE`.

## Owner decisions

| Question | Decision |
|---|---|
| How items are removed | Permanently, not to the Trash. |
| Categories | Safe cleanup, leftovers of deleted apps, iOS backups and large data, emptying the Trash. |
| Full Disk Access | Required. Installing asks for it; without it the scan does not start. |
| Scheduled cleaning | None. Cleaning runs only when a person presses Clean. |

## Flow

Scan → review (each category and item has a checkbox and a size) →
confirmation sheet (item count, total size, the words "cannot be undone",
and the categories involved) → remove → result (freed, failed items listed
by path).

## Item row

`[checkbox or lock] name  ~/short/path  size  [shield] [folder]`

- Left: a checkbox, or a lock icon in its place when the owning app is
  running. A locked item cannot be checked and is never removed; the lock is
  checked again right before removal.
- Right: the size, then a shield button that adds the item to the exception
  list (filled shield; the item stays listed, greyed and unchecked, on every
  later scan until the shield is pressed again), then a folder button that
  reveals the item in Finder at once.
- Exceptions are saved as standardized paths in user defaults.
- Icons are Reicon SVGs (MIT) bundled in `Resources/Icons`, drawn as
  templates; SF Symbols are only the fallback.

## Categories

| Section | Category | Paths | Checked by default |
|---|---|---|---|
| Safe | App caches | `~/Library/Caches/<bundle-id or allow-listed name>`; Apple and shared-infrastructure entries excluded | yes |
| Safe | Logs | `~/Library/Logs/*` and `DiagnosticReports`, files older than 7 days | yes |
| Safe | Developer | Xcode `DerivedData`, `DocumentationCache`, `*DeviceSupport`, `CoreSimulator/Caches` | yes |
| Safe | Browser caches | Safari, Chrome, Edge, Brave, Arc, Firefox cache folders (not profiles, history, cookies or passwords) | yes |
| Safe | Unfinished downloads | `~/Downloads/*.download`, `*.crdownload`, `*.part` not open by any process | yes |
| Review | Deleted-app leftovers | Upstream's bundle-id roots under `~/Library` whose owner app is gone; orphaned user LaunchAgents | no |
| Review | iOS backups | `~/Library/Application Support/MobileSync/Backup/*`, shown with device name and date | no |
| Review | Large developer data | Xcode `Archives`, CoreSimulator `Devices` | no |
| Review | Trash | `~/.Trash` contents as scanned | no |

## Guards (reviewed in the same phase as the code)

Permanent removal raises the bar over upstream's Trash moves:

- Allow-list: only the roots above are ever scanned; nothing outside them
  can become an item.
- Home check: the scan refuses to start unless the home directory is a
  real absolute path that exists and is not `/`.
- Re-check right before removal, per item: same device and inode as at
  scan time, not a symlink, no symlinked ancestor, still a direct child of
  its category root, not a protected path (`/`, `/System`, `/Library`,
  `/Users`, `~`, `~/Library`, `~/Documents`, `~/Desktop`, `~/Downloads`
  itself, and the rest of upstream's list), at least four path components.
- Running apps: caches, browser caches and developer data of a running app
  are skipped and shown as skipped.
- Self and shared infrastructure: FixDock's own bundle id and upstream's
  shared-infrastructure list are never items.
- Trash: only the entries listed at scan time are removed, one by one with
  the same re-check; nothing added after the scan, and no other volume's
  Trash.
- iOS backups: a second confirmation naming each device backup.
- Failures are listed by path; a partial run never reports success.
- No sudo, no Finder AppleScript, no external command-line tools.

## Not ported

Scheduling, screenshots cleanup, Finder escalation for root-owned items,
WhatsApp, upstream tests (FixDock has no test target).
