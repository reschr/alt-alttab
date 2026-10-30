# Alternative AltTab

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

The app adds an overlapping-rectangles icon to the menu bar. On launch, grant **AltAltTab** access in **System Settings → Privacy & Security → Accessibility**. The menu also contains **Open Accessibility Settings…**. After granting access, open the app's menu again to enable the shortcut; its status should read **Option-Tab is ready**. Permission is checked at launch, when the menu opens, and before switching, with no periodic permission timer. When macOS reports that the input hook has been disabled, the app stops interception and cancels switching. After restoring permission, open the menu to restart the shortcut. A timeout also stops the shortcut until the menu is opened.

If an older copy is already running, quit it before reopening the rebuilt app:

```sh
pkill -x AltAltTab
open .build/AltAltTab.app
```

Quit other apps using Option-Tab while testing, so only one switcher handles the shortcut.

## Switching windows

- Hold **Option** and press **Tab** to select the next window on the focused monitor and current desktop.
- Keep holding Option and press Tab again to cycle. Add **Shift** to cycle backward.
- Release **Option** to focus the selected window. Press **Escape** to cancel.
- Move the pointer over a row to select it, then click to focus that window immediately. Opening the panel or cycling with the keyboard keeps the keyboard selection until the pointer moves. You can also click a window in the menu-bar list.

The panel shows app icons and window titles, with no previews. Its list stays fixed while Option is held. A mouse click outside the panel, another shortcut, a desktop/display change, or a change to the active app cancels selection. Closing or moving the selected window prevents activation if it is no longer eligible.

Click an app window on one monitor, then open the menu: only that monitor's current-desktop windows should appear. Repeat on the other monitor. Hidden and minimized windows are excluded. A spanning window belongs to the monitor containing its largest area (ties use display order).

With Accessibility access, the app reads the actual focused window to choose the monitor. Before permission is granted (or if the app does not expose focus), the frontmost ordinary window of the active app is used as a fallback. Moving the pointer to another monitor does not change the selection. If the active app has no eligible window, the list is empty. Stage Manager, unusual app window ordering, and fullscreen behavior still need real-world verification.

Titles are read through Accessibility, with the app name as a fallback. Screen Recording is not requested. Apps that do not expose matching Accessibility windows appear disabled in the menu and are excluded from keyboard cycling. A failed activation plays the system alert sound.

Open this folder in your editor, or open `Package.swift` in Xcode to work on the Swift package. Use the build script to produce the runnable app bundle.

## Validation

Run automated filtering and keyboard-state tests:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
swift test --disable-sandbox --cache-path "$PWD/.build/cache" \
  -Xswiftc -module-cache-path -Xswiftc "$PWD/.build/module-cache"
```

Manually verify pointer selection, clicking a row while holding Option, outside-click cancellation, scrolling long lists, forward/backward cycling, Escape cancellation, two windows belonging to the same app, switching between different apps, and focus on both monitors. Confirm windows on other desktops never enter the panel. Releasing Option after a desktop change must not activate a window from the old list.

## macOS integration limits

Exact AX-to-WindowServer matching uses the undocumented `_AXUIElementGetWindow` system function. It is resolved at runtime; if unavailable, switching is disabled and the menu reports the problem. This dependency may need updating after a macOS release and is unsuitable for a Mac App Store build without replacing it.

The build uses local ad-hoc signing. Rebuilds can invalidate Accessibility grants: if the toggle looks enabled but the shortcut remains unavailable, remove the old AltAltTab entry, add `.build/AltAltTab.app` again (use Command-Shift-G in the file picker to enter its full path), and restart the app. A stable signing identity may be needed later to preserve grants across rebuilds. Public distribution and notarization are outside this initial setup.
