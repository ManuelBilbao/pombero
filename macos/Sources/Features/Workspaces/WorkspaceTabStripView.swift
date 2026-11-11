import AppKit
import SwiftUI

/// The tabs of the visible workspace, drawn inside the window next to the
/// sidebar. While a window has more than one workspace the native tab bar
/// is hidden (it can only span the full window width, above the sidebar)
/// and this strip takes its place at the top of the terminal column.
struct WorkspaceTabStripView: View {
    @ObservedObject var group: TerminalWorkspaceGroup

    /// The terminal background color, tinted the same way as the sidebar.
    let backgroundColor: Color

    let onNewTab: () -> Void
    let onSelectTab: (TerminalController) -> Void
    let onCloseTab: (TerminalController) -> Void

    static let height: CGFloat = 30

    private var tabs: [(controller: TerminalController, window: NSWindow)] {
        group.visibleTabs.compactMap { weak in
            // A closed tab's controller outlives its window for a while;
            // never list it, its window must not be driven or observed.
            guard let controller = weak.value, !controller.windowIsClosing,
                  let window = controller.window, window.isVisible else { return nil }
            return (controller, window)
        }
    }

    var body: some View {
        // Like the native tab bar, a lone tab needs no strip.
        if group.showsSidebar, tabs.count > 1 {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(tabs, id: \.controller) { tab in
                                TabStripItem(
                                    window: tab.window,
                                    isSelected: ObjectIdentifier(tab.controller) == group.selectedTabID,
                                    onSelect: { onSelectTab(tab.controller) },
                                    onClose: { onCloseTab(tab.controller) })
                            }
                        }
                        .padding(.horizontal, 6)
                    }

                    Button(action: onNewTab) {
                        Image(systemName: "plus")
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 6)
                    .help("New Tab")
                    .accessibilityLabel("New Tab")
                }
                .frame(height: Self.height)

                Divider()
            }
            .background(
                ZStack {
                    backgroundColor
                    Color.primary.opacity(0.04)
                }
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tabs")
        }
    }
}

/// One tab in the strip. The title follows the window title, which Ghostty
/// keeps in sync with the focused terminal.
private struct TabStripItem: View {
    let window: NSWindow
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var title: String = ""
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            if let shortcut = (window as? TerminalWindow)?.keyEquivalent, !shortcut.isEmpty {
                Text(shortcut)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Text(title.isEmpty ? "👻" : title)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? .primary : .secondary)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovered || isSelected ? 1 : 0)
            .help("Close Tab")
            .accessibilityLabel("Close Tab")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 24)
        .frame(minWidth: 80, maxWidth: 220)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.primary.opacity(0.12) : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { isHovered = $0 }
        .onReceive(window.publisher(for: \.title, options: [.initial, .new])) { title = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
