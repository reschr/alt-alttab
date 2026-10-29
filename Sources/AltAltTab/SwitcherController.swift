import AppKit
import SwiftUI

struct CycleSelection {
    var index: Int

    mutating func step(count: Int, backward: Bool) {
        guard count > 0 else { index = 0; return }
        index = ((index % count) + count + (backward ? -1 : 1)) % count
    }
}

private struct SwitcherView: View {
    let windows: [WindowDiscovery.Window]
    let selected: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Windows on this monitor").font(.headline)
            ScrollViewReader { reader in
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(windows.indices, id: \.self) { index in
                            HStack(spacing: 12) {
                                if let icon = windows[index].application.icon {
                                    Image(nsImage: icon).resizable().frame(width: 32, height: 32).accessibilityHidden(true)
                                }
                                Text(windows[index].label).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .padding(8)
                            .background(index == selected ? Color.accentColor.opacity(0.3) : .clear)
                            .cornerRadius(8)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(index == selected ? .isSelected : [])
                            .id(index)
                        }
                    }
                }
                .onAppear { reader.scrollTo(selected) }
            }
            Text("Tab to cycle · Shift-Tab to go back · Release Option to switch · Esc to cancel")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
    }
}

@MainActor
final class SwitcherController {
    private var windows: [WindowDiscovery.Window] = []
    private var selection = CycleSelection(index: 0)
    private var panel: NSPanel?
    private var screen: NSScreen?

    func handle(_ command: ShortcutCommand) {
        switch command {
        case .cancel: cancel()
        case .commit:
            let window = windows.indices.contains(selection.index) ? windows[selection.index] : nil
            cancel()
            if let window, !WindowAccess.focus(window) { NSSound.beep() }
        case .step(let backward):
            guard WindowAccess.isTrusted else { cancel(); return }
            if windows.isEmpty {
                windows = (WindowDiscovery.currentDesktopWindows() ?? []).filter { $0.accessibilityElement != nil }
                guard !windows.isEmpty else { NSSound.beep(); return }
                let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
                let focusedID = pid.flatMap { WindowAccess.focusedWindowID(processID: $0) }
                selection.index = windows.firstIndex { $0.snapshot.id == focusedID } ?? 0
                let bounds = windows[selection.index].snapshot.bounds
                let screens = NSScreen.screens
                let displayBounds = screens.map { screen in
                    let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                    return CGDisplayBounds(id)
                }
                if let index = DisplayGeometry.displayIndex(for: bounds, displays: displayBounds) { screen = screens[index] }
            }
            selection.step(count: windows.count, backward: backward)
            showPanel()
        }
    }

    func cancel() {
        panel?.orderOut(nil)
        windows = []
        screen = nil
    }

    private func showPanel() {
        guard let screen else { cancel(); return }
        if panel == nil {
            // A nonactivating panel preserves the user's focused window and monitor.
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.ignoresMouseEvents = true
            panel.backgroundColor = .windowBackgroundColor
            panel.hasShadow = true
            self.panel = panel
        }
        let frame = screen.visibleFrame
        let width = min(620, max(1, frame.width - 40))
        let height = min(CGFloat(windows.count * 56 + 88), 480, max(1, frame.height - 40))
        panel?.contentView = NSHostingView(rootView: SwitcherView(windows: windows, selected: selection.index))
        panel?.setFrame(NSRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height), display: true)
        panel?.orderFrontRegardless()
    }
}
