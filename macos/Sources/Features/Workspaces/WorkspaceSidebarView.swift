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
            // Appearing or disappearing reshuffles focus in the window;
            // the terminal keeps it.
            .onAppear { TerminalWorkspaceGroup.refocusTerminal() }
            .onDisappear { TerminalWorkspaceGroup.refocusTerminal() }
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
                    WorkspaceBadge(
                        workspace: workspace,
                        index: index,
                        isSelected: workspace.id == group.selectedID,
                        size: 26)
                }
                .buttonStyle(.plain)
                .help(workspace.name)
                .accessibilityLabel(workspace.name)
                .contextMenu {
                    WorkspaceMenuItems(
                        workspace: workspace,
                        onClose: { onCloseWorkspace(workspace) },
                        onNew: onNewWorkspace)
                }
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

    var body: some View {
        HStack(spacing: 8) {
            WorkspaceBadge(
                workspace: workspace,
                index: index,
                isSelected: isSelected,
                size: 18)

            Text(workspace.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)

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
        .onTapGesture { onSelect() }
        .contextMenu {
            WorkspaceMenuItems(
                workspace: workspace,
                onClose: onClose,
                onNew: onNew)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// The round badge of a workspace: its number, or the custom character
/// (a letter or an emoji), on the chosen color.
private struct WorkspaceBadge: View {
    @ObservedObject var workspace: TerminalWorkspace
    let index: Int
    let isSelected: Bool
    let size: CGFloat

    /// The gap between the badge and the selection ring, and the ring width.
    /// Their sum is a whole number of points so the badge circle sits on
    /// pixel boundaries inside the ring; a fractional inset renders the
    /// gap a pixel wider on one side than the other.
    private var ringGap: CGFloat { 2.5 }
    private var ringWidth: CGFloat { 1.5 }

    /// Every badge takes the ring's room, selected or not, so the badges
    /// line up and the frame (which focus and menu highlights follow) is
    /// always centered on the circle.
    private var outerSize: CGFloat { size + 2 * (ringGap + ringWidth) }

    var body: some View {
        ZStack {
            // The current workspace wears a thin ring just outside the badge.
            if isSelected {
                Circle().strokeBorder(ringColor, lineWidth: ringWidth)
            }

            ZStack {
                Circle().fill(fill)
                content
                    .foregroundStyle(workspace.color == .none ? Color.primary : Color.white)
            }
            .frame(width: size, height: size)
        }
        .frame(width: outerSize, height: outerSize)
    }

    private var ringColor: Color {
        if let nsColor = workspace.color.displayColor {
            return Color(nsColor: nsColor)
        }
        return Color.accentColor
    }

    private var fill: Color {
        if let nsColor = workspace.color.displayColor {
            return Color(nsColor: nsColor).opacity(isSelected ? 0.95 : 0.55)
        }
        return isSelected ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.06)
    }

    @ViewBuilder private var content: some View {
        let icon = WorkspaceEditPanel.singleCharacter(workspace.icon ?? "")
        if icon.isEmpty {
            Text("\(index + 1)")
                .font(.system(size: size * 0.42, weight: .semibold, design: .monospaced))
        } else {
            Text(icon)
                .font(.system(size: size * 0.5, weight: .semibold))
        }
    }
}

/// The context menu shared by the rail badges and the list rows.
private struct WorkspaceMenuItems: View {
    @ObservedObject var workspace: TerminalWorkspace
    let onClose: () -> Void
    let onNew: () -> Void

    var body: some View {
        Button("Edit Workspace…") { WorkspaceEditPanel.present(for: workspace) }
        Menu("Color") {
            ForEach(TerminalTabColor.allCases, id: \.self) { color in
                Button {
                    workspace.color = color
                } label: {
                    HStack {
                        Image(nsImage: color.swatchImage(selected: workspace.color == color))
                        Text(color.localizedName)
                    }
                }
            }
        }
        Divider()
        Button("Close Workspace", action: onClose)
        Divider()
        Button("New Workspace", action: onNew)
    }
}

/// The "Edit Workspace" sheet: the name and the one-character icon in one
/// dialog, with a button that opens the system emoji palette for the icon.
/// Presented as a sheet on the key window the way Ghostty prompts for tab
/// titles.
final class WorkspaceEditPanel: NSObject, NSTextFieldDelegate {
    /// Panels stay alive while their sheet is up.
    private static var active: Set<WorkspaceEditPanel> = []

    private let workspace: TerminalWorkspace
    private let alert = NSAlert()
    private let nameField = NSTextField(string: "")
    private let iconField = NSTextField(string: "")

    static func present(for workspace: TerminalWorkspace) {
        let panel = WorkspaceEditPanel(workspace)
        active.insert(panel)
        panel.run()
    }

    /// The icon is one character: a letter, a digit or an emoji (one
    /// grapheme, so flags and skin tones stay whole). When more was typed,
    /// the last character wins, which is what replacing feels like.
    static func singleCharacter(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.suffix(1))
    }

    private init(_ workspace: TerminalWorkspace) {
        self.workspace = workspace
        super.init()
        build()
    }

    private func build() {
        alert.messageText = "Edit Workspace"
        alert.informativeText = "The icon is a single character, such as a letter or an emoji. Leave it empty to show the workspace number."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        nameField.stringValue = workspace.name
        nameField.placeholderString = "Name"
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.widthAnchor.constraint(equalToConstant: 240).isActive = true

        iconField.stringValue = workspace.icon ?? ""
        iconField.placeholderString = "–"
        iconField.alignment = .center
        iconField.font = .systemFont(ofSize: 18)
        iconField.delegate = self
        iconField.translatesAutoresizingMaskIntoConstraints = false
        iconField.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let emojiButton = NSButton(
            title: "Emoji & Symbols…",
            target: self,
            action: #selector(openCharacterPalette(_:)))
        emojiButton.bezelStyle = .rounded

        let iconRow = NSStackView(views: [iconField, emojiButton])
        iconRow.orientation = .horizontal
        iconRow.spacing = 8

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Name:"), nameField],
            [NSTextField(labelWithString: "Icon:"), iconRow],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.layoutSubtreeIfNeeded()
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        alert.accessoryView = grid
        alert.window.initialFirstResponder = nameField
        nameField.nextKeyView = iconField
    }

    private func run() {
        let finish: (NSApplication.ModalResponse) -> Void = { [self] response in
            if response == .alertFirstButtonReturn {
                apply()
            }
            Self.active.remove(self)
            TerminalWorkspaceGroup.refocusTerminal()
        }

        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    private func apply() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            workspace.name = name
        }
        let icon = Self.singleCharacter(iconField.stringValue)
        workspace.icon = icon.isEmpty ? nil : icon
    }

    /// Opens the system Character Viewer on the icon field, so a picked
    /// emoji lands there.
    @objc private func openCharacterPalette(_ sender: Any?) {
        alert.window.makeFirstResponder(iconField)
        NSApp.orderFrontCharacterPalette(sender)
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === iconField else { return }
        let limited = Self.singleCharacter(field.stringValue)
        if limited != field.stringValue {
            field.stringValue = limited
        }
    }
}
