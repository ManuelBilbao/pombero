import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A workspace id on the drag pasteboard, used to reorder the sidebar.
    /// Declared in Ghostty-Info.plist so drop targets can match it.
    static let ghosttyWorkspaceId = UTType(exportedAs: "com.mitchellh.ghosttyWorkspaceId")
}

extension NSPasteboard.PasteboardType {
    static let ghosttyWorkspaceId = NSPasteboard.PasteboardType(UTType.ghosttyWorkspaceId.identifier)
}

/// An overlay that makes a sidebar item clickable, right-clickable and
/// draggable with an AppKit drag session, like the split grab handles.
///
/// SwiftUI's own `onDrag` leaves the drag image frozen for a moment after a
/// drop and never says when a drag ended; owning the `NSDraggingSession`
/// gives an immediate end in both cases.
struct WorkspaceDragSource: NSViewRepresentable {
    let workspace: TerminalWorkspace
    let onClick: () -> Void
    let onClose: () -> Void
    let onNew: () -> Void
    /// Called with true when a drag session starts and false when it ends,
    /// whether it was dropped, cancelled or released outside any target.
    let onDragChanged: (Bool) -> Void

    func makeNSView(context: Context) -> WorkspaceDragSourceView {
        let view = WorkspaceDragSourceView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: WorkspaceDragSourceView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: WorkspaceDragSourceView) {
        view.workspace = workspace
        view.onClick = onClick
        view.onClose = onClose
        view.onNew = onNew
        view.onDragChanged = onDragChanged
        view.toolTip = workspace.name
    }
}

final class WorkspaceDragSourceView: NSView, NSDraggingSource {
    var workspace: TerminalWorkspace?
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    var onNew: (() -> Void)?
    var onDragChanged: ((Bool) -> Void)?

    /// Where the mouse went down, while deciding between a click and a drag.
    private var mouseDownLocation: NSPoint?

    /// Movement before a press becomes a drag, in points.
    private static let dragThreshold: CGFloat = 4

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Click or drag

    override func mouseDown(with event: NSEvent) {
        // Consumed: a press is a click until it moves far enough to drag.
        mouseDownLocation = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation else { return }
        let location = event.locationInWindow
        guard hypot(location.x - start.x, location.y - start.y) >= Self.dragThreshold else { return }
        mouseDownLocation = nil
        beginDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownLocation != nil else { return }
        mouseDownLocation = nil
        onClick?()
    }

    private func beginDrag(with event: NSEvent) {
        guard let workspace else { return }

        let pasteboardItem = NSPasteboardItem()
        let data = withUnsafeBytes(of: workspace.id.uuid) { Data($0) }
        pasteboardItem.setData(data, forType: .ghosttyWorkspaceId)
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)

        // The drag image is what is under this overlay: the row or badge.
        item.setDraggingFrame(bounds, contents: snapshotBeneath())

        onDragChanged?(true)
        let session = beginDraggingSession(with: [item], event: event, source: self)

        // Without this a drag released outside a target slides the image
        // back (or lingers) before `endedAt` fires.
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    /// Renders the window content under this view's frame.
    private func snapshotBeneath() -> NSImage? {
        guard let contentView = window?.contentView else { return nil }
        let rect = convert(bounds, to: contentView)
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        contentView.cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let workspace else { return nil }
        let menu = NSMenu()

        menu.addItem(withTitle: "Edit Workspace…", action: #selector(editWorkspace), keyEquivalent: "").target = self

        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu()
        for color in TerminalTabColor.allCases {
            let item = NSMenuItem(title: color.localizedName, action: #selector(setColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = color.rawValue
            item.image = color.swatchImage(selected: workspace.color == color)
            item.state = workspace.color == color ? .on : .off
            colorMenu.addItem(item)
        }
        colorItem.submenu = colorMenu
        menu.addItem(colorItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Close Workspace", action: #selector(closeWorkspace), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "New Workspace", action: #selector(newWorkspace), keyEquivalent: "").target = self
        return menu
    }

    @objc private func editWorkspace() {
        guard let workspace else { return }
        WorkspaceEditPanel.present(for: workspace)
    }

    @objc private func setColor(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int,
              let color = TerminalTabColor(rawValue: raw) else { return }
        workspace?.color = color
    }

    @objc private func closeWorkspace() {
        onClose?()
    }

    @objc private func newWorkspace() {
        onNew?()
    }

    // MARK: NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        onDragChanged?(false)
    }
}
