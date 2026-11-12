import AppKit
import SwiftUI

/// The tabs of the visible workspace, drawn inside the window next to the
/// sidebar. While a window has more than one workspace the native tab bar
/// is hidden (it can only span the full window width, above the sidebar)
/// and this strip takes its place at the top of the terminal column.
struct WorkspaceTabStripView: View {
    @ObservedObject var group: TerminalWorkspaceGroup

    /// The controller of the window this strip is drawn in. Every tab window
    /// has its own strip, and only the one that started a rename edits it.
    let hostID: ObjectIdentifier

    /// The terminal background color, tinted the same way as the sidebar.
    let backgroundColor: Color

    let onNewTab: () -> Void
    let onSelectTab: (TerminalController) -> Void
    let onCloseTab: (TerminalController) -> Void

    static let height: CGFloat = 30

    var body: some View {
        if group.showsTabStrip {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(group.stripTabs, id: \.controller) { tab in
                                let tabID = ObjectIdentifier(tab.controller)
                                TabStripItem(
                                    window: tab.window,
                                    isSelected: tabID == group.selectedTabID,
                                    isRenaming: group.tabRename == .init(tab: tabID, host: hostID),
                                    renameText: tab.controller.titleOverride ?? tab.window.title,
                                    onSelect: { onSelectTab(tab.controller) },
                                    onClose: { onCloseTab(tab.controller) },
                                    onRename: { group.beginRenaming(tab.controller, in: hostID) },
                                    onFinishRename: { title, refocus in
                                        group.finishRenaming(tab.controller, title: title, refocus: refocus)
                                    })
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
/// keeps in sync with the focused terminal or the title the user set.
/// Double-click or "Rename Tab…" edits it in place, like the native tab bar.
private struct TabStripItem: View {
    let window: NSWindow
    let isSelected: Bool
    let isRenaming: Bool

    /// The text the editor starts with: the user's title if there is one,
    /// otherwise the current title.
    let renameText: String

    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: () -> Void

    /// Ends the rename with the new title (nil cancels) and whether to give
    /// keyboard focus back to the terminal.
    let onFinishRename: (String?, Bool) -> Void

    @State private var title: String = ""
    @State private var isHovered = false
    @State private var draft: String = ""
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        // While editing, clicks belong to the text field, so the tab's own
        // tap gestures stand down.
        let tapMask: GestureMask = isRenaming ? .subviews : .all

        HStack(spacing: 6) {
            if let shortcut = (window as? TerminalWindow)?.keyEquivalent, !shortcut.isEmpty {
                Text(shortcut)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if isRenaming {
                editor
            } else {
                Text(title.isEmpty ? "👻" : title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }

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
        .gesture(TapGesture().onEnded { onSelect() }, including: tapMask)
        .simultaneousGesture(TapGesture(count: 2).onEnded { onRename() }, including: tapMask)
        .contextMenu {
            Button("Rename Tab…", action: onRename)
            Divider()
            Button("Close Tab", action: onClose)
        }
        .onHover { isHovered = $0 }
        .onReceive(window.publisher(for: \.title, options: [.initial, .new])) { title = $0 }
        .accessibilityElement(children: isRenaming ? .contain : .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var editor: some View {
        TextField("Tab Title", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .focused($isEditorFocused)
            .onSubmit { onFinishRename(draft, true) }
            .onExitCommand { onFinishRename(nil, true) }
            .onAppear {
                draft = renameText
                // The terminal is first responder; take focus once the
                // field is in the window.
                DispatchQueue.main.async { isEditorFocused = true }
            }
            // Clicking elsewhere keeps the new title, like the native tab
            // bar, and leaves focus where the click put it.
            .onChange(of: isEditorFocused) { focused in
                if !focused { onFinishRename(draft, false) }
            }
            .onDisappear { onFinishRename(draft, false) }
    }
}
