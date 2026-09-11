# Mac images convert

Mac images convert is a native Apple-silicon macOS 26+ app from Event Horizon AI for converting image files locally. It accepts HEIC/HEIF, JPEG, PNG, and static WebP where macOS has a decoder, and writes JPG or PNG.

## What it does

- Shows each source image's original file size and dimensions, then the actual saved size and dimensions after conversion.
- Converts directories and files with no product-imposed batch limit. Work is serially queued to keep memory bounded, and each job can be paused, cancelled, or retried.
- **Convert only:** changes format while keeping original pixel dimensions. File size can change.
- **Resize image:** choose 75%, 50%, 25%, 2048px long-edge, or custom maximum width and height. Custom bounds preserve proportions and never enlarge or stretch. This mode has no MB limit.
- **Fit a file limit:** choose 500 KB, 1 MB, 2 MB (recommended), 5 MB, or a custom KB/MB limit. JPG quality is adjusted first, then dimensions when necessary. PNG preserves lossless encoding and reduces dimensions when needed. A failed target is reported as a failure, never an oversized success.
- Only the selected mode applies. Hidden settings from another mode cannot affect conversion. Inputs apply immediately with inline validation; no Apply button is needed.
- Lets you choose the exact destination folder. Files are written directly there and existing files are never overwritten.
- Can remove embedded GPS metadata with **Hide where photos were taken**. This does not hide landmarks or addresses visible in pixels.
- Can move originals to Trash only after the written output is reopened, decoded, and verified. This is off by default. The app never permanently deletes a file as a fallback.
- Includes a Finder Service, **Convert with Mac images convert**, which sends selected files to the open app. Enable it in macOS Keyboard settings if it does not appear.
- Includes an optional Watch Folder while the app remains open. It waits for file sizes to stabilize, ignores pre-existing files, deduplicates arrivals, and excludes the selected output folder. Watched jobs never move originals to Trash.

Animated and other multi-frame inputs are rejected; the app does not flatten them silently.

## Build a local beta

Requirements: Xcode with macOS 26 SDK, Apple silicon, and macOS 26 or newer.

```sh
swift test
./scripts/build-app.sh
```

The script creates a `.dmg` installer and a `.zip` archive in `dist/`. Open the DMG and drag **Mac images convert** to Applications. The ZIP is useful when you prefer to extract the app directly.

This is a beta build with an **ad-hoc signature**. It is not notarized and is not signed with a Developer ID certificate. No signing claim beyond that is made.

## Tests

`swift test` uses disposable fixtures to check HEIC/JPG conversion, byte caps for JPG and PNG, landscape/portrait bounds, no enlargement, mode switching, input validation, orientation, GPS removal, collision protection, multi-frame rejection, and a three-file batch. No user originals are modified.

## License

MIT. See [LICENSE](LICENSE).
