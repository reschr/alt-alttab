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
