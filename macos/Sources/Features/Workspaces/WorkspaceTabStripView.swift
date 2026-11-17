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

    /// The tab being dragged and the slot it would drop into. The strip
    /// shows the tabs in that order while the drag lasts; the native tab
    /// group is reordered once, on drop.
    @State private var drag: TabDrag?

    /// Each tab's frame in the strip, for placing a drag.
    @State private var tabFrames: [ObjectIdentifier: CGRect] = [:]

    static let height: CGFloat = 30
    private static let coordinateSpace = "WorkspaceTabStrip"

    var body: some View {
        if group.showsTabStrip {
            let tabs = group.stripTabs
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(Self.arrange(tabs, for: drag), id: \.controller) { tab in
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
                                    },
                                    onDragChanged: { dragging in
                                        dragChanged(tabID, dragging: dragging)
                                    })
                                    .opacity(drag?.tab == tabID ? 0.4 : 1)
                                    .background(GeometryReader { proxy in
                                        Color.clear.preference(
                                            key: TabFramesKey.self,
                                            value: [tabID: proxy.frame(in: .named(Self.coordinateSpace))])
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
                // The whole strip is the drop zone, so a release past the
                // last tab or between tabs still lands.
                .coordinateSpace(name: Self.coordinateSpace)
                .onPreferenceChange(TabFramesKey.self) { tabFrames = $0 }
                .onDrop(of: [.ghosttyTabId], delegate: TabReorderDelegate(
                    order: tabs.map { ObjectIdentifier($0.controller) },
                    frames: tabFrames,
                    drag: $drag,
                    onDrop: commit))

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

    /// The tabs in the order to show: the tab group's, with the dragged tab
    /// moved to its drop slot.
    private static func arrange(
        _ tabs: [(controller: TerminalController, window: NSWindow)],
        for drag: TabDrag?
    ) -> [(controller: TerminalController, window: NSWindow)] {
        guard let drag,
              let from = tabs.firstIndex(where: { ObjectIdentifier($0.controller) == drag.tab }) else { return tabs }
        var arranged = tabs
        let moved = arranged.remove(at: from)
        arranged.insert(moved, at: min(drag.index, arranged.count))
        return arranged
    }

    private func dragChanged(_ tab: ObjectIdentifier, dragging: Bool) {
        guard dragging else {
            // A drop already moved the tab; otherwise it slides back.
            withAnimation(.easeInOut(duration: 0.15)) { drag = nil }
            return
        }
        guard let index = group.stripTabs.firstIndex(where: { ObjectIdentifier($0.controller) == tab }) else { return }
        drag = TabDrag(tab: tab, index: index)
    }

    /// Reorder the native tab group to match the drop. Every other tab
    /// keeps its relative order, so this is one move: the dragged tab takes
    /// the place of the tab now in its drop slot.
    private func commit(_ drag: TabDrag) {
        let tabs = group.stripTabs
        guard let from = tabs.firstIndex(where: { ObjectIdentifier($0.controller) == drag.tab }) else { return }
        let to = min(drag.index, tabs.count - 1)
        guard to != from else { return }
        group.moveTab(tabs[from].controller, to: tabs[to].controller)
    }
}

/// A tab being dragged in the strip and its index in the order it would
/// drop into.
private struct TabDrag: Equatable {
    let tab: ObjectIdentifier
    var index: Int
}

private struct TabFramesKey: PreferenceKey {
    static var defaultValue: [ObjectIdentifier: CGRect] = [:]

    static func reduce(value: inout [ObjectIdentifier: CGRect], nextValue: () -> [ObjectIdentifier: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Places a dragged tab while it moves over the strip. Tabs have different
/// widths, so the slot comes from the pointer against the midpoints of the
/// other tabs rather than from which tab it is over: swapping a narrow tab
/// with a wide one would leave the pointer over the wide one and swap back.
private struct TabReorderDelegate: DropDelegate {
    /// The strip's tabs in tab group order.
    let order: [ObjectIdentifier]
    let frames: [ObjectIdentifier: CGRect]
    @Binding var drag: TabDrag?
    let onDrop: (TabDrag) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        // A tab dragged from another window's strip isn't ours to place.
        drag != nil && info.hasItemsConforming(to: [.ghosttyTabId])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let current = drag else { return DropProposal(operation: .forbidden) }
        move(to: slot(of: current.tab, at: info.location.x))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        // Releasing outside the strip cancels, so show where the tab stays.
        guard let current = drag, let index = order.firstIndex(of: current.tab) else { return }
        move(to: index)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let current = drag else { return false }
        // The slot comes from where the drop happened, not from the
        // preview, so it doesn't matter whether `dropExited` ran first.
        onDrop(TabDrag(tab: current.tab, index: slot(of: current.tab, at: info.location.x)))
        // The tab group has the new order now. Clearing here also keeps a
        // late `dropExited` from showing the old slot again.
        drag = nil
        return true
    }

    /// The index the dragged tab would drop into with the pointer at `x`:
    /// the number of other tabs whose middle is left of it.
    private func slot(of tab: ObjectIdentifier, at x: CGFloat) -> Int {
        order.filter { id in
            id != tab && (frames[id]?.midX ?? .infinity) < x
        }.count
    }

    private func move(to index: Int) {
        guard let current = drag, current.index != index else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            drag = TabDrag(tab: current.tab, index: index)
        }
    }
}

/// One tab in the strip. The title follows the window title, which Ghostty
/// keeps in sync with the focused terminal or the title the user set.
/// Double-click or "Rename Tab…" edits it in place, like the native tab bar,
/// and dragging it reorders the strip.
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

    let onDragChanged: (Bool) -> Void

    @State private var title: String = ""
    @State private var isHovered = false
    @State private var draft: String = ""
    @FocusState private var isEditorFocused: Bool

    private static let closeButtonSize: CGFloat = 16

    var body: some View {
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

                Spacer(minLength: 0)
            }

            // Room for the close button, which is drawn above the drag
            // source so its clicks don't select or drag the tab.
            Color.clear
                .frame(width: Self.closeButtonSize, height: Self.closeButtonSize)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 24)
        .frame(minWidth: 80, maxWidth: 220)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.primary.opacity(0.12) : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
        )
        // Clicks, double-clicks, the context menu, hover and drags all go
        // through the AppKit overlay. While editing it steps aside for the
        // text field.
        .overlay(WorkspaceTabDragSource(
            tabWindow: window,
            passesThrough: isRenaming,
            onSelect: onSelect,
            onRename: onRename,
            onClose: onClose,
            onHover: { isHovered = $0 },
            onDragChanged: onDragChanged))
        .overlay(alignment: .trailing) {
            closeButton
                .padding(.trailing, 4)
        }
        .onReceive(window.publisher(for: \.title, options: [.initial, .new])) { title = $0 }
        .accessibilityElement(children: isRenaming ? .contain : .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { onSelect() }
        .accessibilityAction(named: "Rename Tab") { onRename() }
        .accessibilityAction(named: "Close Tab") { onClose() }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: Self.closeButtonSize, height: Self.closeButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(isHovered || isSelected ? 1 : 0)
        .help("Close Tab")
        .accessibilityLabel("Close Tab")
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
