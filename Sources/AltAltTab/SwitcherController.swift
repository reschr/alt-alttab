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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    // Share the row metrics with the panel so short lists fit without empty space.
    static let rowHeight: CGFloat = 64
    static let rowSpacing: CGFloat = 4
    static let chromeHeight: CGFloat = 96

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.on.rectangle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Windows").font(.headline)
                Text("On this monitor").foregroundStyle(.secondary)
                Spacer()
                Text("\(selected + 1) of \(windows.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding(.horizontal, 20)
            .frame(height: 44)

            Divider().padding(.horizontal, 20)
            ScrollViewReader { reader in
                ScrollView {
                    VStack(spacing: Self.rowSpacing) {
                        ForEach(windows.indices, id: \.self) { index in
                            row(at: index).id(index)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.automatic)
                // The panel is rebuilt on each keypress; reveal the selection immediately.
                .onAppear { reader.scrollTo(selected) }
            }

            Divider().padding(.horizontal, 20)
            HStack(spacing: 12) {
                Text("⇥ Next   ⇧⇥ Previous")
                Spacer(minLength: 8)
                Text("Release ⌥ to switch")
                Text("Esc Cancel")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .frame(height: 34)
            .accessibilityLabel("Tab for next, Shift-Tab for previous. Release Option to switch. Escape to cancel.")
        }
        // A semantic AppKit material blends with windows behind this floating panel.
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                SwitcherMaterial()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: contrast == .increased ? 2 : 1)
                .allowsHitTesting(false)
        }
    }

    private func row(at index: Int) -> some View {
        let window = windows[index]
        let isSelected = index == selected
        let appName = window.application.localizedName ?? "Unknown app"
        // Use the system's paired selection colors to stay legible with any accent color.
        let foreground = isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .primary

        return HStack(spacing: 12) {
            Group {
                if let icon = window.application.icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "macwindow").resizable().scaledToFit().padding(6)
                }
            }
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(appName).font(.body.weight(.semibold))
                if let title = window.title, title != appName {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(isSelected ? foreground : .secondary)
                }
            }
            .lineLimit(1)
            .truncationMode(.middle)

            Spacer(minLength: 8)
            // A symbol also identifies the selection without relying on color alone.
            Image(systemName: "checkmark")
                .font(.body.weight(.medium))
                .opacity(isSelected ? 1 : 0)
                .accessibilityHidden(true)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 12)
        .frame(height: Self.rowHeight)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .selectedContentBackgroundColor))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SwitcherMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        // Nonactivating panels never become key, but this transient surface is in use.
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
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
            // Clear backing lets the material and rounded corners reach the desktop.
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            self.panel = panel
        }
        let frame = screen.visibleFrame
        let width = min(560, max(1, frame.width - 40))
        let listHeight = CGFloat(windows.count) * SwitcherView.rowHeight
            + CGFloat(max(0, windows.count - 1)) * SwitcherView.rowSpacing
        let height = min(listHeight + SwitcherView.chromeHeight, 540, max(1, frame.height - 40))
        panel?.contentView = NSHostingView(rootView: SwitcherView(windows: windows, selected: selection.index))
        panel?.setFrame(NSRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height), display: true)
        panel?.orderFrontRegardless()
    }
}
