import AppKit
import ApplicationServices
import Darwin
import OSLog

@MainActor
enum WindowAccess {
    private static let logger = Logger(subsystem: "local.alt-alttab", category: "WindowAccess")
    // Public AX APIs have no window ID. Resolve this private bridge dynamically so
    // a macOS update removing it disables switching instead of crashing at launch.
    private typealias WindowIDFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let windowIDFunction: WindowIDFunction? = {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: WindowIDFunction.self)
    }()

    static var supportsWindowIDs: Bool { windowIDFunction != nil }
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        // The SDK imports this constant as mutable global state; use its fixed key in Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard let function = windowIDFunction, function(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    static func focusedWindowID(processID: pid_t) -> CGWindowID? {
        guard isTrusted else { return nil }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let value = attribute(kAXFocusedWindowAttribute, of: app),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return windowID(of: value as! AXUIElement)
    }

    static func windows(processID: pid_t) -> [CGWindowID: AXUIElement] {
        guard isTrusted else { return [:] }
        let app = AXUIElementCreateApplication(processID)
        // A hung app must not hold the switcher indefinitely.
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let elements = attribute(kAXWindowsAttribute, of: app) as? [AXUIElement] else { return [:] }
        var result: [CGWindowID: AXUIElement] = [:]
        for element in elements {
            AXUIElementSetMessagingTimeout(element, 0.2)
            if let id = windowID(of: element) { result[id] = element }
        }
        return result
    }

    static func focus(_ window: WindowDiscovery.Window) -> Bool {
        // Recheck current Space/monitor membership: a window can move or close
        // while the selection panel is open. Never activate a substitute window.
        guard isTrusted,
              let fresh = WindowDiscovery.currentDesktopWindows()?.first(where: {
                  $0.snapshot.id == window.snapshot.id && $0.snapshot.processID == window.snapshot.processID
              }), let element = fresh.accessibilityElement else { return false }
        let app = AXUIElementCreateApplication(fresh.snapshot.processID)
        AXUIElementSetMessagingTimeout(app, 0.2)
        _ = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        // A background app may reject or time out raising; still request activation, then retry.
        _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, element)
        guard fresh.application.activate(options: [.activateIgnoringOtherApps]) else {
            logger.error("App activation rejected for PID \(fresh.snapshot.processID)")
            return false
        }
        let result = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        if result == .success { return true }
        // AX can time out after performing the action; verify the app and exact selected window.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == fresh.snapshot.processID,
           focusedWindowID(processID: fresh.snapshot.processID) == fresh.snapshot.id { return true }
        logger.error("Window raise failed for PID \(fresh.snapshot.processID), window \(fresh.snapshot.id), AX error \(result.rawValue)")
        return false
    }
}
