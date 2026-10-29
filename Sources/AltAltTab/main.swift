import AppKit

// Refresh discovery when the menu opens so desktop changes need no polling timer.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "rectangle.on.rectangle",
            accessibilityDescription: "AltAltTab"
        )

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        // NSStatusBar does not retain the item for us.
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Windows on focused monitor", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        if let windows = WindowDiscovery.currentDesktopWindows() {
            if windows.isEmpty {
                menu.addItem(withTitle: "No windows found", action: nil, keyEquivalent: "")
            }
            for window in windows {
                let appName = window.application.localizedName ?? "Unknown app"
                let label = window.snapshot.title.map { "\(appName) — \($0)" } ?? appName
                let entry = NSMenuItem(title: label, action: nil, keyEquivalent: "")
                // Copy the shared app icon before resizing it for the menu.
                if let icon = window.application.icon?.copy() as? NSImage {
                    icon.size = NSSize(width: 16, height: 16)
                    entry.image = icon
                }
                menu.addItem(entry)
            }
        } else {
            menu.addItem(withTitle: "Could not read the window list", action: nil, keyEquivalent: "")
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit AltAltTab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// This utility lives in the menu bar rather than the Dock.
application.setActivationPolicy(.accessory)
application.run()
