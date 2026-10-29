import AppKit

struct WindowSnapshot {
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
    struct Window {
        let snapshot: WindowSnapshot
        let application: NSRunningApplication
        let accessibilityElement: AXUIElement?
        let title: String?

        var label: String {
            let appName = application.localizedName ?? "Unknown app"
            return title.map { "\(appName) — \($0)" } ?? appName
        }
    }

    static func currentDesktopWindows() -> [Window]? {
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
            return Window(snapshot: snapshot, application: application, accessibilityElement: nil, title: snapshot.title)
        }

        // Use Quartz coordinates for both windows and displays: AppKit flips the Y axis.
        let displays = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            return CGDisplayBounds(number.uint32Value)
        }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focusedID = frontmostPID.flatMap { WindowAccess.focusedWindowID(processID: $0) }
        // Before permission is granted, retain the previously validated focus approximation.
        let focusedWindow = windows.first { $0.snapshot.id == focusedID }
            ?? windows.first { $0.snapshot.processID == frontmostPID }
        guard let focusedWindow,
              let focusedDisplay = DisplayGeometry.displayIndex(for: focusedWindow.snapshot.bounds, displays: displays)
        else {
            // With no active ordinary window (for example the desktop), show no candidates.
            return []
        }
        let candidates = windows.filter {
            DisplayGeometry.displayIndex(for: $0.snapshot.bounds, displays: displays) == focusedDisplay
        }
        // Ask each app once, and only for candidates on the selected monitor.
        var elementsByProcess: [pid_t: [CGWindowID: AXUIElement]] = [:]
        return candidates.map { window in
            let pid = window.snapshot.processID
            if elementsByProcess[pid] == nil { elementsByProcess[pid] = WindowAccess.windows(processID: pid) }
            let element = elementsByProcess[pid]?[window.snapshot.id]
            let title = element.flatMap { WindowAccess.attribute(kAXTitleAttribute, of: $0) as? String }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Window(
                snapshot: window.snapshot, application: window.application, accessibilityElement: element,
                title: title?.isEmpty == false ? title : window.snapshot.title
            )
        }
    }
}
