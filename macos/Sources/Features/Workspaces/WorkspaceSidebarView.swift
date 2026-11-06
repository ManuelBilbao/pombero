import SwiftUI

/// The sidebar listing a window's workspaces.
///
/// Renders nothing while the window has a single workspace, so hosts can
/// place it unconditionally. With more than one workspace it is either the
/// full list or, when collapsed, a narrow rail of numbered buttons.
struct WorkspaceSidebarView: View {
    @ObservedObject var group: TerminalWorkspaceGroup

    /// The terminal background color. The sidebar tints it slightly so it
    /// reads as chrome rather than as part of the terminal.
    let backgroundColor: Color

    let onNewWorkspace: () -> Void
    let onCloseWorkspace: (TerminalWorkspace) -> Void

    static let expandedWidth: CGFloat = 200
    static let collapsedWidth: CGFloat = 44

    var body: some View {
        if group.showsSidebar {
            HStack(spacing: 0) {
                if group.isSidebarCollapsed {
                    rail
                    Divider()
                } else {
                    list
                    SidebarResizeHandle(group: group)
                }
            }
            .frame(width: group.isSidebarCollapsed ? Self.collapsedWidth : group.sidebarWidth)
            .background(
                ZStack {
                    backgroundColor
                    Color.primary.opacity(0.04)
                }
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Workspaces")
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Workspaces")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    group.isSidebarCollapsed = true
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Collapse Sidebar")
                .accessibilityLabel("Collapse Sidebar")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(group.workspaces.enumerated()), id: \.element.id) { index, workspace in
                        WorkspaceRow(
                            workspace: workspace,
                            index: index,
                            isSelected: workspace.id == group.selectedID,
                            onSelect: { group.select(workspace) },
                            onClose: { onCloseWorkspace(workspace) },
                            onNew: onNewWorkspace)
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)

            Button(action: onNewWorkspace) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("New Workspace")
                }
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var rail: some View {
        VStack(spacing: 6) {
            Button {
                group.isSidebarCollapsed = false
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .help("Expand Sidebar")
            .accessibilityLabel("Expand Sidebar")

            ForEach(Array(group.workspaces.enumerated()), id: \.element.id) { index, workspace in
                Button {
                    group.select(workspace)
                } label: {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .frame(width: 26, height: 26)
                        .background(
                            Circle().fill(workspace.id == group.selectedID
                                          ? Color.accentColor.opacity(0.3)
                                          : Color.primary.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .help(workspace.name)
                .accessibilityLabel(workspace.name)
            }

            Spacer()

            Button(action: onNewWorkspace) {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.bottom, 10)
            .help("New Workspace")
            .accessibilityLabel("New Workspace")
        }
        .frame(maxWidth: .infinity)
    }
}

/// The sidebar's trailing edge: a hairline with a wider invisible grab area
/// that resizes the sidebar when dragged, like a split divider.
private struct SidebarResizeHandle: View {
    @ObservedObject var group: TerminalWorkspaceGroup

    /// The width when the drag started, so the drag is applied as an offset.
    @State private var dragStartWidth: CGFloat?

    static let grabWidth: CGFloat = 8

    var body: some View {
        ZStack(alignment: .trailing) {
            Color.clear
                .frame(width: Self.grabWidth)
                .contentShape(Rectangle())
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1)
        }
        .frame(maxHeight: .infinity)
        .backport.pointerStyle(.resizeLeftRight)
        .onHover { isHovered in
            // macOS 15+ uses pointerStyle above; older systems need the
            // manual cursor push/pop, see SplitView.Divider.
            if #available(macOS 15, *) { return }
            if isHovered {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            // Global coordinates: the handle itself moves as the width
            // changes, so a local translation would be measured against a
            // moving origin and lag or oscillate behind the pointer.
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { gesture in
                    let start = dragStartWidth ?? group.sidebarWidth
                    dragStartWidth = start
                    group.setSidebarWidth(start + gesture.translation.width, persist: false)
                }
                .onEnded { gesture in
                    let start = dragStartWidth ?? group.sidebarWidth
                    dragStartWidth = nil
                    group.setSidebarWidth(start + gesture.translation.width)
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Workspace sidebar divider")
        .accessibilityValue("\(Int(group.sidebarWidth)) points")
        .accessibilityHint("Drag to resize the workspace sidebar")
        .accessibilityAddTraits(.isButton)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: group.setSidebarWidth(group.sidebarWidth + 10)
            case .decrement: group.setSidebarWidth(group.sidebarWidth - 10)
            @unknown default: break
            }
        }
    }
}

/// One workspace in the expanded sidebar. Click selects, the context menu
/// renames or closes.
private struct WorkspaceRow: View {
    @ObservedObject var workspace: TerminalWorkspace
    let index: Int
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onNew: () -> Void

    @State private var isRenaming = false
    @State private var draft = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .trailing)

            if isRenaming {
                TextField("Name", text: $draft, onCommit: commitRename)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($renameFocused)
                    .onExitCommand { endRename() }
            } else {
                Text(workspace.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            let tabCount = workspace.controllers.count
            if tabCount > 1 {
                Text("\(tabCount)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(tabCount) tabs")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.3) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isRenaming else { return }
            onSelect()
        }
        .contextMenu {
            Button("Rename…") { beginRename() }
            Button("Close Workspace") { onClose() }
            Divider()
            Button("New Workspace") { onNew() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private func beginRename() {
        draft = workspace.name
        isRenaming = true
        // The field is not in the hierarchy yet when the menu item runs.
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            workspace.name = trimmed
        }
        endRename()
    }

    private func endRename() {
        isRenaming = false
        renameFocused = false

        // Hand keyboard focus back to the terminal that had it. The text
        // field was first responder, and nothing else claims focus when it
        // goes away.
        if let window = NSApp.keyWindow,
           let controller = window.windowController as? BaseTerminalController,
           let surface = controller.focusedSurface {
            DispatchQueue.main.async { Ghostty.moveFocus(to: surface) }
        }
    }
}
