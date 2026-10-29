import AppKit

// Keep the first app small: a menu-bar entry confirms the native app runs.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "rectangle.on.rectangle",
            accessibilityDescription: "AltAltTab"
        )

        let menu = NSMenu()
        let title = NSMenuItem(title: "AltAltTab — setup ready", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit AltAltTab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu

        // NSStatusBar does not retain the item for us.
        statusItem = item
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// This utility lives in the menu bar rather than the Dock.
application.setActivationPolicy(.accessory)
application.run()
