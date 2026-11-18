import AppKit
import ApplicationServices
import Darwin
import OSLog

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

    static func offMain<Result: Sendable>(_ work: @escaping @Sendable () -> Result) async -> Result {
        // AX messages are synchronous. Keep them off the run loop servicing the event tap.
        let task = Task.detached(priority: .userInitiated, operation: work)
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

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
        let element = value as! AXUIElement
        // AX timeouts apply to the exact element, not its parent app.
        AXUIElementSetMessagingTimeout(element, 0.2)
        return windowID(of: element)
    }

    static func windows(processID: pid_t, matching targetID: CGWindowID? = nil) -> [CGWindowID: AXUIElement] {
        guard !Task.isCancelled, isTrusted, supportsWindowIDs else { return [:] }
        let app = AXUIElementCreateApplication(processID)
        // A hung app must not hold the switcher indefinitely.
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let elements = attribute(kAXWindowsAttribute, of: app) as? [AXUIElement] else { return [:] }
        var result: [CGWindowID: AXUIElement] = [:]
        for element in elements {
            guard !Task.isCancelled else { return [:] }
            AXUIElementSetMessagingTimeout(element, 0.2)
            guard let id = windowID(of: element), targetID == nil || id == targetID else { continue }
            result[id] = element
            if targetID != nil { break }
        }
        return result
    }

    @MainActor
    static func focus(_ window: WindowDiscovery.Window) async -> Bool {
        guard !Task.isCancelled, let context = WindowDiscovery.currentContext() else { return false }
        return await offMain { focus(window, in: context) }
    }

    private static func focus(_ window: WindowDiscovery.Window, in context: WindowDiscovery.Context) -> Bool {
        // Recheck current Space/monitor membership: a window can move or close
        // while the selection panel is open. Never activate a substitute window.
        let target = window.snapshot
        guard !Task.isCancelled, isTrusted,
              let scope = context.scope(),
              scope.windows.contains(where: { $0.snapshot.id == target.id && $0.snapshot.processID == target.processID }),
              let element = windows(processID: target.processID, matching: target.id)[target.id],
              !Task.isCancelled else { return false }
        let app = AXUIElementCreateApplication(target.processID)
        AXUIElementSetMessagingTimeout(app, 0.2)
        _ = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        // A background app may reject or time out raising; still request activation, then retry.
        _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, element)
        guard !Task.isCancelled, isTrusted, !window.application.isTerminated else { return false }
        guard window.application.activate(options: [.activateIgnoringOtherApps]) else {
            logger.error("App activation rejected for PID \(target.processID)")
            return false
        }
        let result = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        if result == .success { return true }
        // AX can time out after performing the action; verify the app and exact selected window.
        if window.application.isActive, focusedWindowID(processID: target.processID) == target.id { return true }
        logger.error("Window raise failed for PID \(target.processID), window \(target.id), AX error \(result.rawValue)")
        return false
    }
}
