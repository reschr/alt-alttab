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

The app adds an overlapping-rectangles icon to the menu bar. Open it to inspect windows on the current desktop, listed front to back. Switch desktops and open the menu again to refresh. Entries are informational for now; window switching is not implemented yet.

Click an app window on one monitor, then open the menu: only that monitor's current-desktop windows should appear. Repeat on the other monitor. Hidden and minimized windows are excluded. A spanning window belongs to the monitor containing its largest area (ties use display order).

Until Accessibility support is added, focus is approximated by the frontmost ordinary window of the active app. Moving the pointer to another monitor does not change the selection. If the active app has no eligible window, the list is empty. Stage Manager, unusual app window ordering, and fullscreen behavior still need real-world verification.

macOS may withhold window titles; those entries show the app name instead. This discovery step does not request Screen Recording or Accessibility access.

Open this folder in your editor, or open `Package.swift` in Xcode to work on the Swift package. Use the build script to produce the runnable app bundle.

## Implementation plan

1. Validate current-Space discovery with real apps (implemented in the menu).
2. Focus a selected window through macOS Accessibility APIs.
3. Add Option-Tab cycling and an icon-and-title selection panel.
4. Verify multiple windows per app, desktop changes, and multiple monitors.

Start with non-minimized windows. Accessibility permission will be required when window switching is added. The app currently requests no permissions.

The build uses local ad-hoc signing. A stable signing identity may be needed later to preserve Accessibility grants across rebuilds. Public distribution and notarization are outside this initial setup.
