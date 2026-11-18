import AppKit

// Refresh discovery when the menu opens so desktop changes need no polling timer.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let shortcut = GlobalShortcut()
    private let switcher = SwitcherController()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private var menuDiscoveryTask: Task<Void, Never>?
    private var shortcutStatus = "Accessibility permission needed"
    private let statusMenuItem = NSMenuItem()
    private let loadingMenuItem = NSMenuItem(title: "Loading windows…", action: nil, keyEquivalent: "")

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

        shortcut.onCommand = { [weak self] command in
            guard let self else { return }
            if case .step = command, !WindowAccess.isTrusted {
                self.cancelSwitching()
                return
            }
            self.switcher.handle(command)
        }
        shortcut.containsMouseLocation = { [weak self] point in self?.switcher.containsMouseLocation(point) ?? false }
        // A click completes the session before Option-up can commit it a second time.
        switcher.onMouseCommit = { [weak self] in self?.shortcut.cancel() }
        // Cancel a frozen selection if its desktop, display, or frontmost app changes.
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let activatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let processID = notification.name == NSWorkspace.didActivateApplicationNotification
                    ? activatedApp?.processIdentifier : nil
                MainActor.assumeIsolated {
                    self?.cancelSwitching(exceptActivationOf: processID)
                }
            })
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.cancelSwitching() } }

        if !WindowAccess.isTrusted { WindowAccess.requestPermission() }
        refreshShortcut()
        menuNeedsUpdate(menu)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menuDiscoveryTask == nil else { return }
        menu.removeAllItems()
        statusMenuItem.title = shortcutStatus
        menu.addItem(statusMenuItem)
        let permission = menu.addItem(withTitle: "Open Accessibility Settings…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        permission.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Windows on focused monitor", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        menu.addItem(loadingMenuItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit AltAltTab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    func menuWillOpen(_ menu: NSMenu) {
        cancelSwitching()
        // Only launch or an explicit menu open can restart a stopped input tap.
        refreshShortcut()
        menuDiscoveryTask?.cancel()
        menuDiscoveryTask = Task { [weak self] in
            guard !Task.isCancelled, let self else { return }
            // AppKit reserves menuWillOpen for notification, so update items after it returns.
            self.statusMenuItem.title = self.shortcutStatus
            let windows = await WindowDiscovery.currentDesktopWindows()?.windows
            guard !Task.isCancelled else { return }
            let index = menu.index(of: self.loadingMenuItem)
            guard index >= 0 else { return }
            menu.removeItem(at: index)
            for (offset, item) in self.windowMenuItems(windows).enumerated() {
                menu.insertItem(item, at: index + offset)
            }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuDiscoveryTask?.cancel()
        menuDiscoveryTask = nil
    }

    private func windowMenuItems(_ windows: [WindowDiscovery.Window]?) -> [NSMenuItem] {
        guard let windows, !windows.isEmpty else {
            let title = windows == nil ? "Could not read the window list" : "No windows found"
            return [NSMenuItem(title: title, action: nil, keyEquivalent: "")]
        }
        return windows.map { window in
            let entry = NSMenuItem(
                title: window.label,
                action: window.isSwitchable ? #selector(selectWindow(_:)) : nil,
                keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = window
            // Copy the shared app icon before resizing it for the menu.
            if let icon = window.application.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                entry.image = icon
            }
            return entry
        }
    }

    @objc private func selectWindow(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? WindowDiscovery.Window else { return }
        // Let the menu finish closing before asking another app to take focus.
        DispatchQueue.main.async {
            self.switcher.activate(window)
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

    private func cancelSwitching(exceptActivationOf processID: pid_t? = nil) {
        shortcut.cancel()
        switcher.cancel()
        switcher.cancelActivation(except: processID)
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcut.stop()
        switcher.cancelActivation()
        menuDiscoveryTask?.cancel()
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
