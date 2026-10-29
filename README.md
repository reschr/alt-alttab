# AltAltTab

A native macOS window switcher focused on the current desktop (Space), with icons and titles instead of previews.

## Requirements

- macOS 13 or later
- Xcode with its command-line tools selected (`xcode-select -p`)
- Swift 6 or later

No third-party dependencies or paid Apple developer account are needed for local development.

## Build and run

```sh
bash scripts/build.sh
open .build/AltAltTab.app
```

The scaffold adds an overlapping-rectangles icon to the menu bar. Use its menu to quit. Window switching is not implemented yet.

Open this folder in your editor, or open `Package.swift` in Xcode to work on the Swift package. Use the build script to produce the runnable app bundle.

## Implementation plan

1. Discover ordinary windows on the current Space and validate filtering with real apps.
2. Focus a selected window through macOS Accessibility APIs.
3. Add Option-Tab cycling and an icon-and-title selection panel.
4. Verify multiple windows per app, desktop changes, and multiple monitors.

Start with non-minimized windows. Accessibility permission will be required when window switching is added. The app currently requests no permissions.

The build uses local ad-hoc signing. A stable signing identity may be needed later to preserve Accessibility grants across rebuilds. Public distribution and notarization are outside this initial setup.
