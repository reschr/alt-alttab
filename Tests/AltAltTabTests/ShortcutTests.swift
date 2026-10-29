import CoreGraphics
import Foundation
import Testing
@testable import AltAltTab

@Test @MainActor func disabledTapCancelsQueuedSwitchingAndClearsSwallowedKeys() async throws {
    for reason: CGEventType in [.tapDisabledByUserInput, .tapDisabledByTimeout] {
        let shortcut = GlobalShortcut()
        var commands: [ShortcutCommand] = []
        shortcut.onCommand = { commands.append($0) }
        // Exercise the callback without installing a system-wide tap or changing TCC grants.
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true))
        event.flags = .maskAlternate
        #expect(shortcut.process(.keyDown, event))
        event.flags = []
        #expect(!shortcut.process(.flagsChanged, event))
        #expect(!shortcut.process(reason, event))
        #expect(!shortcut.isRunning)
        #expect(!shortcut.process(.keyUp, event))
        // Drain previously queued step/commit work; neither may survive shutdown.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(commands == [.cancel])
    }
}

@Test @MainActor func stoppingShortcutDiscardsQueuedCommands() async throws {
    let shortcut = GlobalShortcut()
    var commands: [ShortcutCommand] = []
    shortcut.onCommand = { commands.append($0) }
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true))
    event.flags = .maskAlternate
    #expect(shortcut.process(.keyDown, event))
    shortcut.stop()
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
    #expect(commands == [.cancel])
    #expect(!shortcut.process(.keyUp, event))
}

@Test func cyclesAndCommitsOnlyWhenOptionIsReleased() {
    var state = ShortcutState()
    let first = state.handle(type: .keyDown, key: 48, flags: .maskAlternate)
    #expect(first.consume)
    #expect(first.command == .step(backward: false))
    #expect(state.handle(type: .keyUp, key: 48, flags: .maskAlternate).consume)
    let reverse = state.handle(type: .keyDown, key: 48, flags: [.maskAlternate, .maskShift])
    #expect(reverse.command == .step(backward: true))
    #expect(state.handle(type: .flagsChanged, key: 56, flags: .maskAlternate).command == nil)
    #expect(state.handle(type: .flagsChanged, key: 58, flags: []).command == .commit)
    #expect(!state.active)
    #expect(state.handle(type: .flagsChanged, key: 58, flags: []).command == nil)
}

@Test func leavesOtherShortcutsAlone() {
    var state = ShortcutState()
    for flags: CGEventFlags in [[], .maskCommand, [.maskAlternate, .maskCommand], [.maskAlternate, .maskControl]] {
        let result = state.handle(type: .keyDown, key: 48, flags: flags)
        #expect(!result.consume)
        #expect(result.command == nil)
    }
}

@Test func escapeCancelsWithoutLeakingKeyUpsOrSwitchingOnRelease() {
    var state = ShortcutState()
    _ = state.handle(type: .keyDown, key: 48, flags: .maskAlternate)
    let escape = state.handle(type: .keyDown, key: 53, flags: .maskAlternate)
    #expect(escape.consume)
    #expect(escape.command == .cancel)
    #expect(state.handle(type: .keyUp, key: 53, flags: .maskAlternate).consume)
    #expect(state.handle(type: .keyUp, key: 48, flags: .maskAlternate).consume)
    #expect(state.handle(type: .flagsChanged, key: 58, flags: []).command == nil)
}

@Test func clicksModifiersAndDesktopChangesCancelSelection() {
    var state = ShortcutState()
    _ = state.handle(type: .keyDown, key: 48, flags: .maskAlternate)
    let click = state.handle(type: .leftMouseDown, key: 0, flags: .maskAlternate)
    #expect(!click.consume)
    #expect(click.command == .cancel)
    _ = state.handle(type: .keyDown, key: 48, flags: .maskAlternate)
    #expect(state.handle(type: .flagsChanged, key: 55, flags: [.maskAlternate, .maskCommand]).command == .cancel)
    _ = state.handle(type: .keyDown, key: 48, flags: .maskAlternate)
    state.cancel()
    #expect(state.handle(type: .flagsChanged, key: 58, flags: []).command == nil)
    #expect(state.handle(type: .keyUp, key: 48, flags: []).consume)
}

@Test func selectionWrapsInBothDirectionsAndHandlesEmptyLists() {
    var selection = CycleSelection(index: 0)
    selection.step(count: 3, backward: true)
    #expect(selection.index == 2)
    selection.step(count: 3, backward: false)
    #expect(selection.index == 0)
    selection.step(count: 1, backward: false)
    #expect(selection.index == 0)
    selection.step(count: 0, backward: true)
    #expect(selection.index == 0)
}

@Test func panelClicksReachRowsWithoutCancellingAndMouseCommitEndsSession() {
    var state = ShortcutState()
    _ = state.handle(type: .keyDown, key: 48, flags: .maskAlternate)
    for type: CGEventType in [.leftMouseDown, .rightMouseDown] {
        let click = state.handle(type: type, key: 0, flags: .maskAlternate, mouseInsideSwitcher: true)
        #expect(!click.consume)
        #expect(click.command == nil)
        #expect(state.active)
    }
    // Row activation cancels keyboard state; releasing Option must not switch again.
    state.cancel()
    #expect(state.handle(type: .flagsChanged, key: 58, flags: []).command == nil)
    #expect(state.handle(type: .keyUp, key: 48, flags: []).consume)
}

@Test @MainActor func eventTapAllowsPanelClicksAndStillCancelsOutsideClicks() async throws {
    let shortcut = GlobalShortcut()
    var commands: [ShortcutCommand] = []
    shortcut.onCommand = { commands.append($0) }
    shortcut.containsMouseLocation = { $0.x == 100 }
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true))
    event.flags = .maskAlternate
    #expect(shortcut.process(.keyDown, event))
    event.location = CGPoint(x: 100, y: 100)
    #expect(!shortcut.process(.leftMouseDown, event))
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
    #expect(commands == [.step(backward: false)])
    event.location = CGPoint(x: 200, y: 100)
    #expect(!shortcut.process(.leftMouseDown, event))
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
    #expect(commands == [.step(backward: false), .cancel])
}

@Test func pointerSelectionRequiresMovementAfterEachKeyboardStep() {
    let initial = CGPoint(x: 100, y: 100)
    var pointer = PointerSelection(location: initial)
    // Showing the panel or scrolling a different row under the cursor is not mouse input.
    #expect(pointer.moved(to: initial) == false)
    #expect(pointer.moved(to: initial) == false)
    let moved = CGPoint(x: 101, y: 100)
    #expect(pointer.moved(to: moved) == true)
    #expect(pointer.moved(to: moved) == false)
    // Keyboard cycling resets the baseline, even after the mouse has selected a row.
    pointer = PointerSelection(location: moved)
    #expect(pointer.moved(to: moved) == false)
    #expect(pointer.moved(to: CGPoint(x: 101, y: 101)) == true)
}
