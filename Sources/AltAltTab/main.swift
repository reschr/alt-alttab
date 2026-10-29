import AppKit

// Refresh discovery when the menu opens so desktop changes need no polling timer.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let shortcut = GlobalShortcut()
    private let switcher = SwitcherController()
    private var permissionTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private var shortcutStatus = "Accessibility permission needed"

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

        shortcut.onCommand = { [weak self] command in self?.switcher.handle(command) }
        // Cancel a frozen selection if its desktop, display, or frontmost app changes.
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelSwitching() }
            })
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.cancelSwitching() } }

        if !WindowAccess.isTrusted { WindowAccess.requestPermission() }
        refreshShortcut()
        // Permission can be granted while the app runs; no relaunch is required for a first grant.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshShortcut() }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        cancelSwitching()
        refreshShortcut()
        menu.removeAllItems()
        menu.addItem(withTitle: shortcutStatus, action: nil, keyEquivalent: "")
        let permission = menu.addItem(withTitle: "Open Accessibility Settings…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        permission.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Windows on focused monitor", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        if let windows = WindowDiscovery.currentDesktopWindows() {
            if windows.isEmpty {
                menu.addItem(withTitle: "No windows found", action: nil, keyEquivalent: "")
            }
            for window in windows {
                let entry = NSMenuItem(
                    title: window.label,
                    action: window.accessibilityElement == nil ? nil : #selector(selectWindow(_:)),
                    keyEquivalent: ""
                )
                entry.target = self
                entry.representedObject = window
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

    @objc private func selectWindow(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? WindowDiscovery.Window else { return }
        // Let the menu finish closing before asking another app to take focus.
        DispatchQueue.main.async {
            if !WindowAccess.focus(window) { NSSound.beep() }
        }
    }

    @objc private func openAccessibilitySettings() {
        WindowAccess.requestPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshShortcut() {
        guard WindowAccess.isTrusted else {
            if shortcut.isRunning { shortcut.stop() }
            shortcutStatus = "Accessibility permission needed"
            return
        }
        guard WindowAccess.supportsWindowIDs else {
            if shortcut.isRunning { shortcut.stop() }
            shortcutStatus = "Window switching unavailable on this macOS version"
            return
        }
        shortcutStatus = shortcut.start() ? "Option-Tab is ready" : "Shortcut unavailable — check Accessibility and restart"
    }

    private func cancelSwitching() {
        shortcut.cancel()
        switcher.cancel()
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        shortcut.stop()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// This utility lives in the menu bar rather than the Dock.
application.setActivationPolicy(.accessory)
application.run()
