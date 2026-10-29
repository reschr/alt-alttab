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
