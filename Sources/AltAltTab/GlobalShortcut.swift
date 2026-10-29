import AppKit

enum ShortcutCommand: Equatable {
    case step(backward: Bool), commit, cancel
}

// Keep event decisions separate from UI and AX calls so key handling is testable.
struct ShortcutState {
    private(set) var active = false
    private var swallowedKeys: Set<Int64> = []

    mutating func handle(type: CGEventType, key: Int64, flags: CGEventFlags) -> (consume: Bool, command: ShortcutCommand?) {
        if type == .keyUp { return (swallowedKeys.remove(key) != nil, nil) }
        if type == .flagsChanged, active {
            if !flags.contains(.maskAlternate) {
                active = false
                return (false, .commit)
            }
            if !flags.intersection([.maskCommand, .maskControl]).isEmpty {
                active = false
                return (false, .cancel)
            }
        }
        if type == .keyDown {
            if key == 48, flags.contains(.maskAlternate), flags.intersection([.maskCommand, .maskControl]).isEmpty {
                active = true
                swallowedKeys.insert(key)
                return (true, .step(backward: flags.contains(.maskShift)))
            }
            if active {
                active = false
                if key == 53 { swallowedKeys.insert(key) }
                return (key == 53, .cancel)
            }
        }
        if active, type == .leftMouseDown || type == .rightMouseDown {
            active = false
            return (false, .cancel)
        }
        return (false, nil)
    }

    mutating func cancel() {
        // Preserve swallowed key-ups after cancellation so the target app sees no orphan Tab.
        active = false
    }
}

@MainActor
final class GlobalShortcut {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var state = ShortcutState()
    var onCommand: ((ShortcutCommand) -> Void)?
    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                // The tap source is installed exclusively on the main run loop.
                let consume = MainActor.assumeIsolated {
                    Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue().process(type, event)
                }
                return consume ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        state = ShortcutState()
        onCommand?(.cancel)
    }

    func cancel() { state.cancel() }

    private func process(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            state.cancel()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            DispatchQueue.main.async { self.onCommand?(.cancel) }
            return false
        }
        let result = state.handle(type: type, key: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags)
        if let command = result.command {
            // Returning quickly avoids event-tap timeouts when another app's AX server is slow.
            DispatchQueue.main.async { self.onCommand?(command) }
        }
        return result.consume
    }
}
