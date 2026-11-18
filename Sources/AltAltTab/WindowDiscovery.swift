import AppKit

struct WindowSnapshot: Sendable {
    let id: CGWindowID
    let processID: pid_t
    let title: String?
    let bounds: CGRect

    init?(info: [String: Any]) {
        // WindowServer also reports menus, invisible surfaces, and desktop widgets.
        guard let id = info[kCGWindowNumber as String] as? UInt32,
              let processID = info[kCGWindowOwnerPID as String] as? Int32,
              let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
              let onScreen = info[kCGWindowIsOnscreen as String] as? Bool, onScreen,
              let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0,
              let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsInfo),
              bounds.width > 1, bounds.height > 1 else { return nil }

        self.id = id
        self.processID = processID
        self.bounds = bounds
        // Titles can be redacted by macOS; keep the window even when its title is absent.
        let title = (info[kCGWindowName as String] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title?.isEmpty == false ? title : nil
    }
}

enum DisplayGeometry {
    static func displayIndex(for window: CGRect, displays: [CGRect]) -> Int? {
        // Assign spanning windows to the monitor containing the largest portion.
        // Strict comparison makes ties deterministic: the first display wins.
        var bestIndex: Int?
        var bestArea: CGFloat = 0
        for (index, display) in displays.enumerated() {
            let overlap = window.intersection(display)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestArea {
                bestIndex = index
                bestArea = area
            }
        }
        return bestIndex
    }
}

@MainActor
enum WindowDiscovery {
    struct Window: Sendable {
        let snapshot: WindowSnapshot
        let application: NSRunningApplication
        let isSwitchable: Bool
        let title: String?

        var label: String {
            let appName = application.localizedName ?? "Unknown app"
            return title.map { "\(appName) — \($0)" } ?? appName
        }
    }

    struct Desktop {
        let screen: NSScreen?
        let focusedWindowID: CGWindowID?
        let windows: [Window]
    }

    struct Context: Sendable {
        let windows: [Window]
        let displayBounds: [CGRect]
        let frontmostPID: pid_t?

        func scope() -> (display: Int, focusedWindowID: CGWindowID, windows: [Window])? {
            let focusedID = frontmostPID.flatMap { WindowAccess.focusedWindowID(processID: $0) }
            // Without Accessibility focus, use the frontmost ordinary window of the active app.
            let focusedWindow = windows.first { $0.snapshot.id == focusedID }
                ?? windows.first { $0.snapshot.processID == frontmostPID }
            guard !Task.isCancelled,
                  let focusedWindow,
                  let display = DisplayGeometry.displayIndex(for: focusedWindow.snapshot.bounds, displays: displayBounds)
            else { return nil }
            let candidates = windows.filter {
                DisplayGeometry.displayIndex(for: $0.snapshot.bounds, displays: displayBounds) == display
            }
            return (display, focusedWindow.snapshot.id, candidates)
        }
    }

    private static func capture() -> (context: Context, screens: [NSScreen])? {
        // Onscreen enumeration excludes other Spaces and minimized/hidden windows.
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        // Preserve WindowServer's front-to-back order and exclude background helpers.
        let windows: [Window] = info.compactMap { entry in
            guard let snapshot = WindowSnapshot(info: entry),
                  snapshot.processID != ProcessInfo.processInfo.processIdentifier,
                  let application = NSRunningApplication(processIdentifier: snapshot.processID),
                  application.activationPolicy == .regular else { return nil }
            return Window(snapshot: snapshot, application: application, isSwitchable: false, title: snapshot.title)
        }

        // Use Quartz coordinates for both windows and displays: AppKit flips the Y axis.
        let displays = NSScreen.screens.compactMap { screen -> (screen: NSScreen, bounds: CGRect)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            return (screen, CGDisplayBounds(number.uint32Value))
        }
        return (
            Context(windows: windows, displayBounds: displays.map(\.bounds),
                    frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier),
            displays.map(\.screen)
        )
    }

    static func currentContext() -> Context? { capture()?.context }

    static func currentDesktopWindows() async -> Desktop? {
        guard let (context, screens) = capture() else { return nil }
        guard let result = await WindowAccess.offMain({ resolve(context) }) else {
            // With no active ordinary window (for example the desktop), show no candidates.
            return Desktop(screen: nil, focusedWindowID: nil, windows: [])
        }
        return Desktop(screen: screens[result.display], focusedWindowID: result.focusedWindowID, windows: result.windows)
    }

    private nonisolated static func resolve(_ context: Context) -> (display: Int, focusedWindowID: CGWindowID, windows: [Window])? {
        guard let scope = context.scope() else { return nil }
        // Ask each app once, and only for candidates on the selected monitor.
        var elementsByProcess: [pid_t: [CGWindowID: AXUIElement]] = [:]
        var matches: [Window] = []
        for window in scope.windows {
            guard !Task.isCancelled else { return nil }
            let pid = window.snapshot.processID
            if elementsByProcess[pid] == nil { elementsByProcess[pid] = WindowAccess.windows(processID: pid) }
            let element = elementsByProcess[pid]?[window.snapshot.id]
            let title = element.flatMap { WindowAccess.attribute(kAXTitleAttribute, of: $0) as? String }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            matches.append(Window(
                snapshot: window.snapshot, application: window.application, isSwitchable: element != nil,
                title: title?.isEmpty == false ? title : window.snapshot.title
            ))
        }
        return (scope.display, scope.focusedWindowID, matches)
    }
}
