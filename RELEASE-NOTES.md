# 0.3.0 beta

- Added **Images to PDF** inside the existing app.
- Arrange page order before creating the PDF.
- Choose image-sized pages, A4, or US Letter with automatic portrait and landscape pages.
- Combine HEIC, JPG, PNG, and static WebP into one PDF and choose the output folder.

# 0.2.2 beta

- Added **Check for Updates…** to the app menu and Settings.
- Checks public GitHub Releases without an account or token.
- Opens the latest DMG download when a newer version is available.

# 0.2.1 beta

Fixes converted images appearing upside down. The decoder now applies the source file's EXIF orientation before resizing and encoding, using Apple's ImageIO rendering path.

Validation covers every EXIF orientation (1–8) at the pixel level, plus HEIC conversion, JPG/PNG size limits, resize bounds, metadata removal and batch conversion.

Download the new DMG, quit the previous app, then drag Mac images convert to Applications and replace the old version. Requires macOS 26 or later on Apple silicon.

This beta is ad-hoc signed and has not been notarized by Apple. The installation security warning is unchanged.

## 0.2.0 beta

Choose a purpose instead of juggling Dimensions and Size:

- Convert only: keep original dimensions and change format.
- Resize image: choose smaller dimensions or custom maximum width and height.
- Fit a file limit: enter a website's KB/MB limit and let the app adjust automatically.

Custom fields now have visible borders, separate labels, units, immediate updates, and validation. Custom bounds preserve proportions and never enlarge or stretch. Hidden settings from other modes no longer affect output.

The window fits at its minimum width, with scrolling settings and a destination bar that stays visible. Results show original and saved size/dimensions, with Show in Finder and Convert these again.

Validation: 11 automated tests passed, including HEIC conversion, JPG/PNG limits, portrait/landscape bounds, and mode changes. Native UI checks exercised typing custom pixels, selecting a destination, converting HEIC, and producing a 9808-byte JPG for a 10 KB limit. Minimum-width layout was visually inspected.

Download the DMG, quit the previous app, then drag Mac images convert to Applications and replace the old version. Requires macOS 26 or later on Apple silicon.

This beta is ad-hoc signed and has not been notarized by Apple. The installation security warning is unchanged.
