# Media tool and AirDrop auto-zip design

Status: agreed with the owner 2026-10-29. Built in three pull requests:

1. Shared image engine + Media tool, image compression.
2. Media tool, video compression.
3. AirDrop auto-zip on the same image engine.

## Sources compared

- `SPEC.md` (owner's brainstorm for the auto-zip).
- The owner's web image compressor (`image-compress.ts`, `ImageCompressor.tsx`).
- Upstream vorssaint-utils `mediaTools` at `1cdbd59b` (`Services/Media/*`,
  `UI/Media/MediaWorkspaceView.swift`).

## Shared image engine (best of the three)

| Concern | Choice | Taken from |
|---|---|---|
| Compression levels | Low 90, Medium 75 (default), High 50, as a segmented bar; no custom value | owner's compressor numbers, upstream's Low/Medium/High wording |
| Result larger than the original | Keep the original bytes when the format is unchanged | owner's compressor (upstream only warned) |
| Metadata | Keep, remove GPS (default), or remove all | new; upstream only had all-or-nothing |
| GPS removal check | The written file is read back; any GPS left fails the file closed | new |
| GPS on the never-bigger path | Lossless copy with `kCGImageMetadataShouldExcludeGPS` instead of the raw original | new |
| Colour | No redraw when size and format are unchanged, so P3/HDR survive | improves upstream (always redrew to device RGB 8-bit) |
| Decode | ImageIO thumbnail decode with transform, capped pixel count | upstream |
| Orientation | Applied to pixels on the redraw path, tag reset to up | upstream |
| Alpha into JPEG | Flattened onto white | owner's compressor, upstream |
| Animated images | Passed through unchanged (no first-frame-only output) | new |
| Saving | Staged, then moved with `RENAME_EXCL`; never overwrites; collisions get " 2", " 3" | upstream |
| Batches | One file at a time on a serial queue, `autoreleasepool` per file, cancellable | upstream, improved |

## Media tool

- A new catalog tool, `mediaTools`, in the Tools group. Installed, it adds a
  Settings page that is the workspace; the menu panel row opens it.
- Manual only: files come from the file picker or a drop on the page.
- Image defaults: original format and size, Medium, remove GPS, one zip.
  Options: format (original, JPEG, PNG, HEIC), longest edge limit, metadata,
  output (one zip or separate files).
- Output: one `compressed_images_YYYY-MM-DD.zip` in the first image's folder
  (images keep their names inside), or `name-compressed.ext` next to each
  original. Originals are never modified or moved.
- The menu panel card has the drop zone, level and output; the Settings page
  adds format, size and metadata. Leaving the page or closing the panel
  clears the results.
- Video: an Image | Video bar picks the tool. Resolution mode runs
  `/usr/bin/avconvert` with the level picking the size (Low up to 1080p,
  Medium 720p, High 540p, never upscaled); file-size mode (1–512 MB, default
  25) encodes with AVAssetWriter in up to three passes and fails rather than
  leave a file over the target. Both write MP4 H.264 with no location or other
  private metadata. The zip/files choice is shared with images. Not ported:
  trimming, HEVC, GIF.
- Not ported: OCR, GIF maker, watermark, profiles, PDF output, rename
  patterns, Notch and Quick Launcher entry points.

## AirDrop auto-zip (pull request 3)

| Question | Decision |
|---|---|
| Which files | Images received by AirDrop only: `com.apple.quarantine` agent is `sharingd`. |
| Compression | Its own level setting (Low, Medium, High), default Medium. Original format and size, GPS removed. |
| Names inside the zip | `1.heic`, `2.jpg`, … in capture-time order. |
| Zip | `compressed_images_YYYY-MM-DD.zip` in `~/Downloads`; `_2` and so on for later batches that day. |
| Originals | `FileManager.trashItem`, only after the zip is verified. Never `rm`. |
| Videos and other files | Left where they are. |
| Finish notice | Notification Center, success and failure. |
| Network | None. |

Flow: FSEvents on `~/Downloads`; files present when the watch starts are
never processed; a batch closes 5 seconds after the last candidate once sizes
are stable; the engine writes into a private folder under
`~/Library/Caches/<bundle id>/`; `/usr/bin/ditto -c -k` writes the zip to a
temporary name; verification is ditto exit 0, exactly N entries, each
non-empty; then the zip is renamed into place and the originals trashed.

Guards: nothing is trashed unless it belongs to a verified zip; non-images,
non-AirDrop files, files present before the watch and the app's own zips are
never candidates; any failure keeps every original; files arriving during a
batch go to the next one; turning the tool off stops the watch.

## Open items to confirm on the Mac

- AirDrop photos carry the `sharingd` quarantine agent (seen on an AirDrop
  mp4; photos not yet checked).
- Whether macOS asks for Downloads access the first time.
- HEIC at Medium is smaller than the iPhone original in practice.
