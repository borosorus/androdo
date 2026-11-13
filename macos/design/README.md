# Androdo window and identity study

This study compares two original marks in the same proposed full-window layout:

- **A — Folded A:** an archive-spine monogram with a copper folded stroke.
- **B — Phone/archive:** a simplified version of the current device/archive motif.

The bare glyph and wordmark occupy a stable titlebar position aligned with the
sidebar. A colored tile is reserved for the Dock/app icon. The comparison page
shows these treatments together, including 16/24-pixel glyph samples.

## Generate and open

From the repository root, using Python's standard library:

```sh
python3 macos/design/window_study.py
open dist/androdo-window-study/index.html
```

The page is self-contained. Its controls switch concept, screen, light/dark
appearance, and standard/compact/collapsed-sidebar layouts. These controls only
change the illustration. App controls drawn inside the window do not operate.
The page makes no network requests or filesystem reads.

Optional PNG exports use an already installed `rsvg-convert`:

```sh
python3 macos/design/window_study.py --render-png
```

Generated HTML, SVG and PNG files live under ignored `dist/`; source stays here.
No app modules, user defaults, backup repositories, phone content or device
transport are used. All names, dates, counts, file choices and statuses are
fictional. This script reads only its adjacent HTML template and writes the
chosen output directory; the comparison page embeds all drawings inline.

## Proposed UX

- Overview prioritizes the latest **complete backup for the displayed device**;
  USB connection is a separate, quiet status.
- A smaller device illustration leaves room for readable destination and scope
  settings. Selected names are visible without opening an editor.
- First use has one primary connection action and an offline backup-folder path.
- The library keeps native-style split browsing and labels incomplete points.
- Progress remains in a persistent strip with cancellation; another backup action
  is unavailable while one is running.
- Copper identifies the archive/history motif; system blue remains the main
  action/selection color. Bare brand glyphs adapt for light and dark surfaces.

## Limits and decision

These are vector design studies, not screenshots, SwiftUI previews, or a working
app implementation. Window chrome, shadows, fonts and controls are approximated.
Their geometry helps evaluate the composition at 1120×720 and 900×600, but does
not verify actual macOS toolbar behavior, responsive layout, VoiceOver or keyboard
interaction. The study does not replace the existing app icon or change Androdo.

After selecting the mark, implement the titlebar integration and readiness states
in SwiftUI. A real latest-backup summary needs a device-bound repository query;
the current library selection may belong to another device and cannot supply
that fact without matching it first. Keep all generated fixture values out of the
production app. Validate the real window and toolbar with the sidebar expanded
and collapsed before considering the design implemented.
