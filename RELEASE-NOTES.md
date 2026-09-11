# 0.2.0 beta

Choose a purpose instead of juggling Dimensions and Size:

- Convert only: keep original dimensions and change format.
- Resize image: choose smaller dimensions or custom maximum width and height.
- Fit a file limit: enter a website's KB/MB limit and let the app adjust automatically.

Custom fields now have visible borders, separate labels, units, immediate updates, and validation. Custom bounds preserve proportions and never enlarge or stretch. Hidden settings from other modes no longer affect output.

The window fits at its minimum width, with scrolling settings and a destination bar that stays visible. Results show original and saved size/dimensions, with Show in Finder and Convert these again.

Validation: 11 automated tests passed, including HEIC conversion, JPG/PNG limits, portrait/landscape bounds, and mode changes. Native UI checks exercised typing custom pixels, selecting a destination, converting HEIC, and producing a 9808-byte JPG for a 10 KB limit. Minimum-width layout was visually inspected.

Download the DMG, quit the previous app, then drag Mac images convert to Applications and replace the old version. Requires macOS 26 or later on Apple silicon.

This beta is ad-hoc signed and has not been notarized by Apple. The installation security warning is unchanged.
