import AppKit
import CoreGraphics
import Testing
@testable import AltAltTab

// Fixtures cover non-window surfaces commonly mixed into WindowServer results.
private func windowInfo() -> [String: Any] {
    [
        kCGWindowNumber as String: UInt32(42),
        kCGWindowOwnerPID as String: Int32(123),
        kCGWindowLayer as String: 0,
        kCGWindowIsOnscreen as String: true,
        kCGWindowAlpha as String: 1.0,
        kCGWindowBounds as String: CGRect(x: 10, y: 20, width: 800, height: 600).dictionaryRepresentation,
        kCGWindowName as String: "  Document  "
    ]
}

@Test func keepsOrdinaryWindowsWithoutRequiringTitles() {
    var info = windowInfo()
    #expect(WindowSnapshot(info: info)?.title == "Document")
    info.removeValue(forKey: kCGWindowName as String)
    #expect(WindowSnapshot(info: info)?.id == 42)
    #expect(WindowSnapshot(info: info)?.title == nil)
}

@Test func excludesOverlaysHiddenWindowsAndTransparentSurfaces() {
    for (key, value) in [
        (kCGWindowLayer as String, 25 as Any),
        (kCGWindowIsOnscreen as String, false as Any),
        (kCGWindowAlpha as String, 0.0 as Any),
        (kCGWindowBounds as String, CGRect(x: 0, y: 0, width: 1, height: 1).dictionaryRepresentation as Any)
    ] {
        var info = windowInfo()
        info[key] = value
        #expect(WindowSnapshot(info: info) == nil)
    }
}

@Test func rejectsIncompleteWindowMetadata() {
    var info = windowInfo()
    info.removeValue(forKey: kCGWindowOwnerPID as String)
    #expect(WindowSnapshot(info: info) == nil)
}

@Test func assignsWindowsToTheMonitorWithMostOverlap() {
    let displays = [
        CGRect(x: 0, y: 0, width: 1000, height: 800),
        CGRect(x: 1000, y: 0, width: 1000, height: 800)
    ]
    #expect(DisplayGeometry.displayIndex(for: CGRect(x: 50, y: 50, width: 800, height: 600), displays: displays) == 0)
    #expect(DisplayGeometry.displayIndex(for: CGRect(x: 900, y: 50, width: 600, height: 600), displays: displays) == 1)
    #expect(DisplayGeometry.displayIndex(for: CGRect(x: 700, y: 50, width: 600, height: 600), displays: displays) == 0)
    #expect(DisplayGeometry.displayIndex(for: CGRect(x: 2000, y: 50, width: 600, height: 600), displays: displays) == nil)
}

@Test func supportsDisplaysAboveAndLeftOfThePrimaryDisplay() {
    // Quartz uses negative coordinates for displays above or to the left.
    let displays = [
        CGRect(x: 0, y: 0, width: 1000, height: 800),
        CGRect(x: -1000, y: -800, width: 1000, height: 800)
    ]
    #expect(DisplayGeometry.displayIndex(for: CGRect(x: -900, y: -700, width: 600, height: 500), displays: displays) == 1)
    #expect(DisplayGeometry.displayIndex(for: CGRect(x: 0, y: 0, width: 500, height: 500), displays: []) == nil)
}

@Test @MainActor func releasingOptionDuringDiscoveryCommitsTheQueuedSelection() async throws {
    let application = NSRunningApplication.current
    let windows = try (1...3).map { number in
        var info = windowInfo()
        info[kCGWindowNumber as String] = UInt32(number)
        let snapshot = try #require(WindowSnapshot(info: info))
        return WindowDiscovery.Window(snapshot: snapshot, application: application, isSwitchable: true, title: nil)
    }
    let desktop = WindowDiscovery.Desktop(screen: nil, focusedWindowID: 1, windows: windows)
    var activated: [CGWindowID] = []
    var discoveryCount = 0
    let (firstQuery, startFirstQuery) = AsyncStream<Void>.makeStream()
    let (firstResult, returnFirstResult) = AsyncStream<Void>.makeStream()
    let switcher = SwitcherController(discover: {
        discoveryCount += 1
        if discoveryCount == 1 {
            startFirstQuery.yield(())
            var results = firstResult.makeAsyncIterator()
            _ = await results.next()
        }
        return desktop
    }) { window in
        activated.append(window.snapshot.id)
        return true
    }

    switcher.handle(.step(backward: true))
    var starts = firstQuery.makeAsyncIterator()
    _ = await starts.next()
    switcher.handle(.commit)
    switcher.cancel()
    returnFirstResult.yield(())

    // These arrive before the async discovery task has a chance to run.
    switcher.handle(.step(backward: false))
    switcher.handle(.step(backward: false))
    switcher.handle(.step(backward: true))
    switcher.handle(.commit)

    for _ in 0..<100 where activated.isEmpty {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(activated == [2])
}

@Test @MainActor func focusConfirmationRequiresTheSelectedWindow() async {
    let wrongWindow = await WindowAccess.confirmFocus(of: 42, timeout: .zero) { 41 }
    #expect(!wrongWindow)

    var observations: [CGWindowID?] = [nil, 41, 42]
    let delayedFocus = await WindowAccess.confirmFocus(of: 42) { observations.removeFirst() }
    #expect(delayedFocus)
    #expect(observations.isEmpty)
}
