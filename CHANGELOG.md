# Changelog

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
