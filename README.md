# Mac images convert

Mac images convert is a native Apple-silicon macOS 26+ app from Event Horizon AI for converting image files locally. It accepts HEIC/HEIF, JPEG, PNG, and static WebP where macOS has a decoder, and writes JPG or PNG.

## What it does

- Shows each source image’s actual file size, dimensions, and frame count.
- Converts directories and files with no product-imposed batch limit. Work is serially queued to keep memory bounded, and each job can be paused, cancelled, or retried.
- Offers original, 75%, 50%, 25%, 2048px long-edge, and custom dimensions. JPEG has High (recommended), Balanced, and Maximum quality settings.
- Applies an optional per-image cap of 500 KB, 1 MB, 2 MB (recommended), 5 MB, or a custom decimal KB/MB value. It lowers JPEG quality first, then optionally reduces dimensions; a job fails instead of reporting an oversized file as successful.
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

The script creates `dist/Mac images convert-0.1.0-beta-macos-arm64.app` and its corresponding zip. It makes an `.icns` from `../../brand-assets/mac-images-convert-icon-final.png`, falling back to the supplied original image only when the final icon is absent.

This is a beta build with an **ad-hoc signature**. It is not notarized and is not signed with a Developer ID certificate. No signing claim beyond that is made.

## Tests

`swift test` programmatically creates disposable fixture images and checks JPG output, a real byte cap, cap failure without downsize permission, EXIF orientation, GPS removal, collision protection, multi-frame rejection, invalid input, and a three-file batch. Fixtures and outputs are contained in a temporary test directory; no user originals are modified.

## License

MIT. See [LICENSE](LICENSE).
