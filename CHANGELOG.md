# Changelog

## Unreleased

- FixDock now describes itself as a small set of menu bar tools for people who use a Mac in Korean (README and the onboarding welcome). The onboarding text names both network uses, the update check and feedback.
- URL cleaner: Naver's ad click token (`NaPm`), its search ad tracking fields (`n_media`, `n_query`, `n_rank`, `n_ad_group`, `n_ad`, `n_keyword_id`, `n_keyword`) and the NT fields (`nt_source`, `nt_medium`, `nt_detail`, `nt_keyword`) are removed on every site. Each can be switched off in Settings › URL cleaner.
- Media: zipping files whose names are not plain ASCII (Hangul, accents) no longer fails. The check after zipping read the names with `zipinfo`, which prints such names as question marks, so the archive never matched and the job reported an error. Names are now read with `bsdtar` in a UTF-8 locale, and are stored precomposed (NFC) so Hangul names are not split into jamo on Windows.
- Clipboard history: the actions (⌘K and the right-click menu) gain "Paste with Korean/English Keys Swapped" for text typed on the wrong layout, up to 2,000 characters: `dkssud` pastes as 안녕, `ㅗ디ㅣㅐ` as hello. The history keeps the text as it was copied.
- Installing several tools at once (Install all, onboarding) asks for one missing permission, the first in tool order, instead of opening System Settings once per tool. Features › Permissions lists the rest.
- Importing settings no longer opens a permission request just before the restart.
- Features › Permissions stops re-reading permissions when the Settings window closes.
- Permission texts name the fast Korean/English switch and the screen recorder.

## 1.1.0

- Self-update: `UpdatePolicy.attemptIsFinished` keeps an attempt folder the helper left without a report for `movedAsideLifetime`, the same rule as `restoreFailed` and `evictionFailed`. Before, a helper that died after moving the installed copy aside (or after the forward swap) and before writing its report let the next sweep delete the previous copy, leaving no working FixDock. Found with a TLA+ model; not reproduced on a real device. A report-less attempt now stays on disk for up to 30 days. (#79)
- Cleanup with no behaviour change: dead code removed, comments moved back onto their declarations or corrected, `build.sh` records `FixDockSourceRevision` when run by a relative path, and the README, CONTRIBUTING and SECURITY text about the build and the network uses matches the code and `PRIVACY.md`. (#80)

## 1.0.9

- Quit protection: the ⌘Q notice no longer gets stuck invisible. FixDock reused one panel for the whole run, and when the system's show fade was cut short by the key-up, the window server kept the panel at alpha 0 while AppKit believed it was 1, so later shows changed nothing. The system fade is off, each show resets the panel's level, alpha and size (and recreates a panel the window server has dropped), and 0.25 s after a show FixDock checks the window server and, if the notice is not on screen, shows it again in a new panel, once per show. Hidden panels are dropped after a display change, wake or session return. Each recovery is written to `diagnostics.log`. Short-tap timing is unchanged.
- Text snippets: Hangul triggers (such as ㅋ1) expand again while the Korean 2-Set source is on; 1.0.8 compared only by key position and missed them. Latin triggers are matched by key position and Hangul triggers by the jamo typed, the longest trigger wins, and the characters to delete are counted with the 2-Set composition rules.

## 1.0.8

- Video compression: the resolution levels (high, medium, low) now encode once with a bitrate cap that is also at most 80% of the source's, so phone videos get smaller at every level. Before, the fixed presets re-encoded at a set rate and an iPhone HEVC clip could come out as large as the original or larger. The target size can be typed as well as stepped; a typed value is clamped to 1...512 MB and text that is not a number reverts to the saved size.
- Text snippets: Latin triggers expand while the Korean 2-Set input source is on. Keys are matched by position, and the characters the Korean input method composed are counted by the 2-Set composition rules before they are deleted.
- Quit protection: the first 20 times the ⌘Q notice is shown each run, FixDock records in `diagnostics.log` whether it reached the screen (front app, macOS version, window number, visibility, occlusion, window server state, frame, screen), right after it is shown and 0.25 s later.
- Settings opens tall enough to show the whole sidebar, down to App › Advanced, capped at the screen's height.

## 1.0.7

- Settings has a native toolbar. The sidebar toggle and Back/Forward sit in one capsule right of the window buttons, followed by the current page's name, which is also the window title. Command-[ and Command-] go back and forward, Control-Command-S shows or hides the sidebar. History records page changes only, not the Features tab, drops pages whose tool was removed, and starts empty each time the window opens.
- A search field at the top of the Settings sidebar finds pages and the labels on them (card titles, toggles, section names, tools and permissions), in the app's language and in English. Results replace the sidebar while you type; choosing one opens its page. The labels come from a typed index in `Sources/FixDock/UI/SettingsSearch.swift`, which every page and tool must fill.

## 1.0.6

- Opened from a disk image (or from a copy macOS runs from a temporary location), FixDock offers to move itself into `/Applications` before it starts anything, and reopens from there. A copy already in `/Applications` is moved to the Trash first, never deleted, and put back if the move fails; a newer installed copy is opened instead. Only a copy signed with the release's Developer ID offers this. The new copy must be notarized and carry the same signature, checked before the move and again in `/Applications`, before it is opened. On an account that cannot write to `/Applications`, FixDock says so and keeps running from the image.
- `Tools/make-dmg.sh` packs the notarized app into a drag-to-install disk image beside an Applications shortcut, then signs, notarizes and staples the image.
- Permission guide: when a tool needs Device Control and Data Access (Accessibility), Screen & System Audio Recording or Full Disk Access, FixDock opens that System Settings pane and shows a card beside the window; dragging the running app's icon from the card into the list adds it. The list area is highlighted when the window is found, and the highlight never blocks clicks or drops. Permission names follow the running macOS in Settings, the panel, onboarding and the guide.
- Settings: Permissions is a tab under Settings › Features. A card above the tool list shows the installed count on a bar, with Install all and Remove all on its right. A collapsible App category at the bottom of the sidebar holds Shortcut, About, Update log and Advanced.
- Settings › Update log shows each release's changes in English or Korean from `Sources/FixDock/Core/Changelog.swift`; `Tools/check-shell.py` fails while its first entry is not the `Info.plist` version.
- Settings › Advanced: export the app's settings to an XML property list and import one back. Import checks the file, asks first, writes a safety copy of the current settings to `SettingsBackups/` in FixDock's Application Support folder, writes only portable keys (tool availability through `FeatureRuntime`) and restarts. Remove all permissions runs `tccutil reset All` on FixDock's own bundle id after a confirmation and restarts.
- Releases attach `FixDock-<version>.dmg` beside the zip; the updater still reads only the zip.

## 1.0.5

- New tool, clipboard history (restored from upstream): Command-Shift-V opens a two-pane window centred on the screen under the pointer. On the left, a search field, a type menu (all types, image, text, link, colour, file, email) and the history grouped Pinned, Today, Yesterday, This week, Earlier; on the right, a preview and details (source app, kind, dimensions, size, path, characters, words, when it was copied). Return pastes into the app you were in, Command-Return copies, ⌘K opens the actions (paste, copy, pin, show in Finder, delete), ⌘P opens the type menu, Option-P pins, Command-Delete removes, Escape closes; a click selects, a double click pastes. Without Accessibility, Return copies and says so.
- Text, pictures and files are recorded. Pictures are kept in FixDock's Application Support folder (pictures over 50 MB or 64 megapixels are skipped); files are kept as their location, the first 32 of a copy, and temporary files are skipped. Text with a picture beside it (a spreadsheet selection) is kept as text. The screenshot tool's copies (picture, QR, recognised text, picked colour) and the recorder's GIF copy are recorded too. Settings › Clipboard history can turn pictures and files off.
- Pinned items stay; the rest is kept for 1, 7, 30 (default) or 90 days or forever, at most 1,000, and pictures up to 250 MB, 1 GB (default), 5 GB or without a limit, oldest first. Copies marked secret or transient by their app and copies made in excluded apps are not recorded; while the URL cleaner is on, links are kept cleaned. The history is `ClipboardHistory.json` beside a `ClipboardHistoryImages` folder; FixDock removes a stored picture only after the history no longer lists it and has been saved. A history file FixDock cannot read is left untouched and recording stops until you deal with it. Another app holding Command-Shift-V receives the key too.

## 1.0.4

- Screenshot pins: every capture now stays on screen as a pin where it was taken, at its own size (shrunk when larger than about half the screen). The corner preview card is gone. Drag to move, drag an edge to resize. A floating bar under the selected pin has Save (and Save As), Copy, Share, Extract Text, Edit, QR when a code was found, a handle to drag the image into other apps, Settings (opacity, shortcuts, Close All) and Close; the right-click menu has the same items. While a pin is selected: ⌘S save, ⇧⌘S Save As, ⌘C copy, ⌘E edit, ⌘T extract text, ⌘W or Esc close. A new capture hides the previous pin; closing the top one brings back the one under it (up to 20). Editing hides the pin and brings it back with the edit. "Show preview" is now "Pin the capture on screen" (on by default), and "Save as a PNG file" is off by default.
- A window captured on a second display is pinned on that display, not the main one.
- Capture sounds: a short focus beep when a drag starts and a shutter when a window, area or whole screen is captured. They follow the system alert volume and sound effects output, and can be turned off in Settings › Screen capture (on by default). The sounds are CC0 clips from Freesound, credited in NOTICE.
- Snap to lines: while you drag a capture area, its corners snap to horizontal and vertical lines within a few points, such as window edges and table rules. Turn it off in Settings › Screen capture (on by default).
- Feedback moved to Settings › General › Feedback, with Bug and Features & Ideas tabs. Send posts the report to the FixDock developer through a small relay; Copy still keeps it on this Mac. Nothing is sent until you press Send. What is sent and who sees it is in PRIVACY.md.

## 1.0.3

- Quit protection and text snippets now say why they hear no keys. While another app holds secure input (a password field, a sign-in window, Terminal's Secure Keyboard Entry), macOS hides typing from both, so ⌘Q passes straight through and snippets do not expand; their Settings pages now show this with the app macOS names. A keyboard monitor macOS refuses to start is shown and retried every few seconds. Both are written to the log (category `keyTaps`).
- Settings › About › Feedback… copies a note together with a diagnostics report (versions, which tools are on, keyboard monitor state and recent events). Nothing is sent; paste it wherever you want. The events are kept in `diagnostics.log` in FixDock's Application Support folder and never include typed text or snippet contents.
- New tool, fast Korean/English switch (adapted from gksdud, MIT): Caps Lock switches the input source on press, without a wrong first letter. FixDock maps Caps Lock to F19 and points "Select the previous input source" at it while the tool is on, and puts both back when you turn it off, quit or uninstall (also after a crash, at the next launch or from `Tools/uninstall.sh`).
- Fast switch: hold the key for half a second to switch to English and turn Caps Lock on or off (on by default).
- Screenshot preview: Copy and Save confirm with a short "Copied!" or "Saved!" at the bottom centre of the screen. Copy now copies again even after the automatic copy and keeps the preview open, so you can still save or edit.
- Screenshot editor: resting the pointer on a tool in the left rail shows its name and key.

## 1.0.2

- Scrolling capture: frames now come from a live stream at up to 60 a second instead of a screenshot every 120 ms, so fast scrolling no longer skips frames. After a skipped frame the capture carries on instead of skipping every later frame, scrolling back up never adds rows twice, and returning to where it stopped leaves no hole.
- Scrolling capture: a sidebar or other fixed panel inside the area no longer breaks matching or repeats down the image; below the first screen it is filled with its background colour. The frame and bar around the area never show up in the picture, and long captures use far less memory.
- Screenshot loupe: Z steps off, regular and large (Shift-Z steps back); large shows 21 × 21 pixels with grid lines. The overlay opens with the loupe on, and a setting can start it off. A cross marks the centre pixel, and thin blue lines through the pointer replace the cursor while the overlay is up.
- Colour copy (C) and the loupe label use the format chosen in Settings › Screen capture: HEX, HEX without #, `rgb()` or `hsl()`.

## 1.0.1

- Updates: FixDock checks its own GitHub releases (about hourly, and when the panel opens) and can download, verify, install and restart into a new version from Settings › About, the panel banner or "Check for Updates…". A version that does not start is rolled back. Only the notarized release in /Applications installs in place; developer and self-built copies never check. Turn it off in Settings › About; what is sent is in PRIVACY.md.
- The update window shows release notes with their headings and lists, and Korean update text writes versions one way.
- Install with Homebrew: `brew install --cask qaws81877/tap/fixdock`.

## 1.0.0

First public release. All nine tools are in; install the ones you want from Settings › Features.

- Quit and close protection: Command-Q and Command-W wait for a confirmation.
- Cleaning mode: the keyboard is locked until Escape is pressed five times.
- Text snippets: a typed trigger expands into saved text.
- Media: images and videos compressed beside the originals, one zip or separate files.
- AirDrop auto-zip: photos received by AirDrop are compressed and zipped, the originals go to the Trash.
- Cleaner: caches, logs, leftovers and backups reviewed by category and removed after a confirmation.
- Screenshot: capture overlay (Control-Option-Command-4), full screen (Control-Option-Command-3), last region, loupe, colour picker, scrolling capture, preview with pin, QR and text copy, and an editor.
- Screen recorder: region, window or display with countdown, pause, microphone and system audio, pointer and typing tracks, a preview, and an editor with trim, zoom, overlays and MP4 or GIF export.
- README and onboarding describe the tools and the permission each one uses.
- Signed with a Developer ID, the hardened runtime and a secure timestamp, and notarized.

## 0.2.0

- URL cleaner. Copied links lose tracking parameters on this Mac. The rules and the manual cleaner are in Settings and in the menu bar panel.

## 0.1.0

First FixDock shell.

- Forked from vorssaint-utils `1cdbd59b1c7dccd036ec1713b2ea048334990d06`.
- Menu bar app, settings, feature catalog, onboarding, permission guide, global shortcut.
- Feature modules are not included. See NOTICE for the full modification list.

The upstream changelog describes vorssaint-utils, not FixDock. It is in the git history of the import merge (`7336fd329db673743444ce169c1373097be9765a`), not in this file.
