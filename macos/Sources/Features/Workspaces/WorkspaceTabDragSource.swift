import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A tab of the workspace tab strip on the drag pasteboard, used to
    /// reorder the strip. Declared in Ghostty-Info.plist so drop targets can
    /// match it.
    static let ghosttyTabId = UTType(exportedAs: "com.mitchellh.ghosttyTabId")
}

extension NSPasteboard.PasteboardType {
    static let ghosttyTabId = NSPasteboard.PasteboardType(UTType.ghosttyTabId.identifier)
}

/// An overlay that makes a tab strip item clickable, double-clickable,
/// right-clickable, hoverable and draggable. Like `WorkspaceDragSource`, it
/// owns the AppKit drag session so the strip learns right away when a drag
/// ends, dropped or not.
struct WorkspaceTabDragSource: NSViewRepresentable {
    /// The window of the tab, written to the drag pasteboard.
    let tabWindow: NSWindow

    /// While the tab is renamed in place, clicks go through to the editor.
    let passesThrough: Bool

    let onSelect: () -> Void
    let onRename: () -> Void
    let onClose: () -> Void
    let onHover: (Bool) -> Void

    /// Called with true when a drag session starts and false when it ends,
    /// whether it was dropped, cancelled or released outside any target.
    let onDragChanged: (Bool) -> Void

    func makeNSView(context: Context) -> WorkspaceTabDragSourceView {
        let view = WorkspaceTabDragSourceView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: WorkspaceTabDragSourceView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: WorkspaceTabDragSourceView) {
        view.tabWindowNumber = tabWindow.windowNumber
        view.passesThrough = passesThrough
        view.onSelect = onSelect
        view.onRename = onRename
        view.onClose = onClose
        view.onHover = onHover
        view.onDragChanged = onDragChanged
    }
}

final class WorkspaceTabDragSourceView: NSView, NSDraggingSource {
    var tabWindowNumber: Int = 0
    var passesThrough = false
    var onSelect: (() -> Void)?
    var onRename: (() -> Void)?
    var onClose: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onDragChanged: ((Bool) -> Void)?

    /// Where the mouse went down, while deciding between a click and a drag.
    private var mouseDownLocation: NSPoint?

    /// Movement before a press becomes a drag, in points.
    private static let dragThreshold: CGFloat = 4

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        passesThrough ? nil : super.hitTest(point)
    }

    // MARK: Hover

    // A tracking area rather than SwiftUI's onHover, which this overlay
    // would stand in front of. It is geometric, so the close button drawn
    // above the overlay still counts as inside the tab.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }

    // MARK: Click or drag

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            mouseDownLocation = nil
            onRename?()
            return
        }
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
        onSelect?()
    }

    private func beginDrag(with event: NSEvent) {
        // The strip tracks the dragged tab itself; the pasteboard only has
        // to carry a type the strip accepts.
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(String(tabWindowNumber), forType: .ghosttyTabId)
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)

        // The drag image is the tab under this overlay.
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
        let menu = NSMenu()
        menu.addItem(withTitle: "Rename Tab…", action: #selector(renameTab), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close Tab", action: #selector(closeTab), keyEquivalent: "").target = self
        return menu
    }

    @objc private func renameTab() {
        onRename?()
    }

    @objc private func closeTab() {
        onClose?()
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
