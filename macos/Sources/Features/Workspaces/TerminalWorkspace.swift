import AppKit
import Combine

/// A workspace is an ordered set of tabs within a window.
///
/// A terminal window (a native tab group) owns one or more workspaces, see
/// `TerminalWorkspaceGroup`. Only the selected workspace's tabs are in the
/// window's tab group; the tabs of every other workspace keep their windows
/// alive but ordered out, so their terminals keep running in the background.
final class TerminalWorkspace: Identifiable, ObservableObject {
    let id: UUID

    /// The user-visible name shown in the sidebar.
    @Published var name: String

    /// The tabs of this workspace in tab bar order. The windows own their
    /// controllers, so these are weak and closed tabs fall out on `prune`.
    @Published private(set) var tabs: [Weak<TerminalController>] = []

    /// The tab that was selected when this workspace was last shown. This is
    /// the tab that becomes key when the workspace is shown again.
    weak var selectedTab: TerminalController?

    init(name: String, id: UUID = UUID()) {
        self.name = name
        self.id = id
    }

    /// The live controllers of this workspace, in order.
    var controllers: [TerminalController] {
        tabs.compactMap(\.value)
    }

    var isEmpty: Bool { controllers.isEmpty }

    func contains(_ controller: TerminalController) -> Bool {
        tabs.contains { $0.value === controller }
    }

    func append(_ controller: TerminalController) {
        guard !contains(controller) else { return }
        tabs.append(Weak(controller))
    }

    func remove(_ controller: TerminalController) {
        tabs.removeAll { $0.value === controller || $0.value == nil }
        if selectedTab === controller { selectedTab = nil }
    }

    /// Replace the tab order with the given controllers. Used to capture the
    /// order of the native tab group before the workspace is hidden.
    func setOrder(_ controllers: [TerminalController]) {
        tabs = controllers.map { Weak($0) }
    }

    /// Drop references to controllers whose windows went away.
    func prune() {
        guard tabs.contains(where: { $0.value == nil }) else { return }
        tabs.removeAll { $0.value == nil }
    }
}

/// The workspaces of a single terminal window.
///
/// Every `TerminalController` in a native tab group shares one group. The
/// group decides which workspace is visible and moves windows in and out of
/// the native tab group when the selection changes.
final class TerminalWorkspaceGroup: ObservableObject {
    let id: UUID

    /// All workspaces in sidebar order. Never empty while the group is in use.
    @Published fileprivate(set) var workspaces: [TerminalWorkspace] = []

    /// The id of the visible workspace.
    @Published fileprivate(set) var selectedID: UUID

    /// Whether the user collapsed the sidebar to its narrow rail. The sidebar
    /// is hidden entirely while there is only one workspace, see
    /// `showsSidebar`.
    @Published var isSidebarCollapsed: Bool = false

    /// The width of the expanded sidebar in points. Dragging the sidebar's
    /// edge sets it; the value is kept in user defaults so every window,
    /// now and after a relaunch, uses the same width.
    @Published private(set) var sidebarWidth: CGFloat = TerminalWorkspaceGroup.storedSidebarWidth()

    static let sidebarWidthRange: ClosedRange<CGFloat> = 140...480
    private static let sidebarWidthKey = "WorkspaceSidebarWidth"

    private static func storedSidebarWidth() -> CGFloat {
        let stored = UserDefaults.ghostty.double(forKey: sidebarWidthKey)
        guard stored > 0 else { return WorkspaceSidebarView.expandedWidth }
        return min(max(CGFloat(stored), sidebarWidthRange.lowerBound), sidebarWidthRange.upperBound)
    }

    /// Set the sidebar width. A live drag passes `persist: false` for every
    /// move and persists once on release; writing defaults per mouse event
    /// is wasted work.
    func setSidebarWidth(_ width: CGFloat, persist: Bool = true) {
        let clamped = min(max(width, Self.sidebarWidthRange.lowerBound), Self.sidebarWidthRange.upperBound)
        if clamped != sidebarWidth {
            sidebarWidth = clamped
        }
        if persist {
            UserDefaults.ghostty.set(Double(clamped), forKey: Self.sidebarWidthKey)
        }
    }

    /// Set while every window of the group is closing so that the removal of
    /// a workspace's last tab doesn't reveal a neighbor workspace.
    var isClosing: Bool = false

    /// The tabs of the visible workspace in tab bar order, for the in-window
    /// tab strip. Refreshed by `syncVisibleTabs`.
    @Published private(set) var visibleTabs: [Weak<TerminalController>] = []

    /// The selected tab of the visible workspace, for the in-window tab strip.
    @Published private(set) var selectedTabID: ObjectIdentifier?


    /// The frame of the last visible window of this group. Used to place the
    /// windows of a workspace that is revealed when no window is on screen.
    var lastFrame: NSRect?

    private var nextWorkspaceNumber: Int = 1

    /// Saved sidebar positions and selection, used while restoring windows.
    private var restoredIndices: [UUID: Int] = [:]
    private var restoredSelectedID: UUID?
    private var didRestoreHidden = false

    /// Creates a group whose first workspace holds the given controller.
    init(initial controller: TerminalController, id: UUID = UUID()) {
        self.id = id
        let workspace = TerminalWorkspace(name: "Workspace 1")
        workspace.append(controller)
        workspace.selectedTab = controller
        self.workspaces = [workspace]
        self.selectedID = workspace.id
        self.nextWorkspaceNumber = 2
        controller.workspaceGroup?.remove(controller)
        controller.workspaceGroup = self
    }

    // MARK: Queries

    var selected: TerminalWorkspace {
        workspaces.first { $0.id == selectedID } ?? workspaces[0]
    }

    var selectedIndex: Int {
        workspaces.firstIndex { $0.id == selectedID } ?? 0
    }

    /// The sidebar is only shown when there is something to choose from.
    var showsSidebar: Bool { workspaces.count > 1 }

    /// Every controller in every workspace.
    var allControllers: [TerminalController] {
        workspaces.flatMap(\.controllers)
    }

    func workspace(id: UUID) -> TerminalWorkspace? {
        workspaces.first { $0.id == id }
    }

    func workspace(containing controller: TerminalController) -> TerminalWorkspace? {
        workspaces.first { $0.contains(controller) }
    }

    // MARK: Membership

    /// Create an empty workspace at the end of the list. The caller is
    /// responsible for giving it a tab before selecting it.
    @discardableResult
    func makeWorkspace(named name: String? = nil, id: UUID = UUID()) -> TerminalWorkspace {
        let number = nextWorkspaceNumber
        nextWorkspaceNumber += 1
        let workspace = TerminalWorkspace(name: name ?? "Workspace \(number)", id: id)
        workspaces.append(workspace)
        return workspace
    }

    /// Add a controller to a workspace of this group, moving it out of any
    /// workspace or group it was in before.
    func add(_ controller: TerminalController, to workspace: TerminalWorkspace) {
        if let other = controller.workspaceGroup, other !== self {
            other.remove(controller)
        }
        if let current = self.workspace(containing: controller), current !== workspace {
            current.remove(controller)
        }
        workspace.append(controller)
        controller.workspaceGroup = self
        objectWillChange.send()
    }

    /// Remove a controller from the group. When this empties a workspace the
    /// workspace is removed too. When that workspace was the selected one,
    /// a neighbor is revealed so the window doesn't vanish while other
    /// workspaces still have tabs.
    func remove(_ controller: TerminalController, revealNeighbor: Bool = true, frame: NSRect? = nil) {
        guard let workspace = workspace(containing: controller) else { return }
        workspace.remove(controller)
        workspace.prune()
        if controller.workspaceGroup === self {
            controller.workspaceGroup = nil
        }

        guard workspace.isEmpty else {
            objectWillChange.send()
            return
        }

        let index = workspaces.firstIndex { $0 === workspace } ?? 0
        workspaces.removeAll { $0 === workspace }
        guard !workspaces.isEmpty else { return }

        if workspace.id == selectedID {
            let neighbor = workspaces[min(index, workspaces.count - 1)]
            selectedID = neighbor.id
            if revealNeighbor, !isClosing {
                reveal(neighbor, anchor: nil, frame: frame ?? lastFrame)
            }
        }
        if !isClosing { syncVisibleTabs() }
    }

    /// Workspace membership can drift because AppKit lets users drag tabs
    /// between windows. Make the group agree with the native tab group that
    /// contains `window`: foreign tabs join the selected workspace, and tabs
    /// of the selected workspace that left for another visible window get a
    /// group of their own.
    func reconcile(with window: NSWindow) {
        guard let me = window.windowController as? TerminalController else { return }
        let visibleWindows = window.tabGroup?.windows ?? [window]
        let visibleControllers = visibleWindows.compactMap { $0.windowController as? TerminalController }

        // The tab group belongs to whichever group most of its tabs are in.
        // If that isn't us, this tab was dragged (or restored) into another
        // window: join it there.
        var counts: [ObjectIdentifier: (group: TerminalWorkspaceGroup, count: Int)] = [:]
        for controller in visibleControllers {
            guard let group = controller.workspaceGroup else { continue }
            let key = ObjectIdentifier(group)
            counts[key] = (group, (counts[key]?.count ?? 0) + 1)
        }
        if let host = counts.values.max(by: { $0.count < $1.count })?.group, host !== self {
            host.add(me, to: host.selected)
            host.selected.selectedTab = me
            host.reconcile(with: window)
            return
        }

        // We own this tab group. Strays in it join the visible workspace.
        // A tab that is closing has left its group and an empty tree; it
        // is not a stray.
        for controller in visibleControllers where controller.workspaceGroup !== self {
            guard !controller.surfaceTree.isEmpty else { continue }
            add(controller, to: selected)
        }

        // Tabs of the visible workspace that are on screen in some other
        // window have left us. If we are alone and they are together, we
        // are the one that left (move_tab_to_new_window, a tab drag).
        let outside = selected.controllers.filter { controller in
            guard let other = controller.window else { return false }
            return other.isVisible && !visibleWindows.contains(other)
        }
        if !outside.isEmpty {
            if visibleWindows.count == 1 {
                remove(me)
                _ = TerminalWorkspaceGroup(initial: me)
                return
            }
            for controller in outside {
                remove(controller, revealNeighbor: false)
                _ = TerminalWorkspaceGroup(initial: controller)
            }
        }

        if selected.contains(me) {
            selected.selectedTab = me
        }
    }

    // MARK: Tab strip

    /// Refresh the tab strip from the native tab group of the visible
    /// workspace. Called whenever a tab is added, closed, reordered or
    /// selected, and after a workspace switch.
    func syncVisibleTabs(from window: NSWindow? = nil) {
        let anchor = window
            ?? selected.controllers.compactMap(\.window).first { $0.isKeyWindow }
            ?? selected.controllers.compactMap(\.window).first { $0.isVisible }
        guard let anchor else {
            if !visibleTabs.isEmpty { visibleTabs = [] }
            return
        }

        let windows = anchor.tabGroup?.windows ?? [anchor]
        let controllers = windows.compactMap { $0.windowController as? TerminalController }
        if controllers.map(ObjectIdentifier.init) != visibleTabs.compactMap({ $0.value.map(ObjectIdentifier.init) }) {
            visibleTabs = controllers.map { Weak($0) }
        }

        let selectedWindow = anchor.tabGroup?.selectedWindow ?? anchor
        let selectedID = (selectedWindow.windowController as? TerminalController).map(ObjectIdentifier.init)
        if selectedID != selectedTabID {
            selectedTabID = selectedID
        }

        syncNativeTabBar(anchor)
    }

    /// The native tab bar can only span the whole window, above the sidebar,
    /// so it is hidden while the sidebar is shown and the strip draws the
    /// tabs instead. It comes back when the window is down to one workspace.
    private func syncNativeTabBar(_ window: NSWindow) {
        let windows = window.tabGroup?.windows ?? [window]
        for case let terminalWindow as TerminalWindow in windows {
            terminalWindow.hidesNativeTabBar = showsSidebar
        }
    }

    // MARK: Selection

    /// Show the given workspace and hide the one that is currently shown.
    func select(_ workspace: TerminalWorkspace) {
        guard workspace.id != selectedID else { return }
        guard workspaces.contains(where: { $0 === workspace }) else { return }
        let current = selected

        // Remember the tab order and selection of the workspace we leave so
        // it comes back the way the user left it.
        let anchor = current.controllers.compactMap(\.window).first { $0.isKeyWindow }
            ?? current.controllers.compactMap(\.window).first { $0.isVisible }
        if let tabGroup = anchor?.tabGroup {
            current.setOrder(tabGroup.windows.compactMap { $0.windowController as? TerminalController })
            current.selectedTab = tabGroup.selectedWindow?.windowController as? TerminalController
        } else if let anchor {
            current.selectedTab = anchor.windowController as? TerminalController
        }
        if let anchor { lastFrame = anchor.frame }

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        reveal(workspace, anchor: anchor, frame: anchor?.frame ?? lastFrame)
        hide(current)
        NSAnimationContext.endGrouping()

        selectedID = workspace.id
        syncVisibleTabs()
    }

    func select(index: Int) {
        guard workspaces.indices.contains(index) else { return }
        select(workspaces[index])
    }

    /// Bring a workspace's windows on screen. With a visible `anchor` the
    /// windows join its tab group, otherwise the first window is shown
    /// standalone at `frame` and the rest become its tabs.
    private func reveal(_ workspace: TerminalWorkspace, anchor: NSWindow?, frame: NSRect?) {
        workspace.prune()
        let controllers = workspace.controllers
        guard let first = controllers.first else { return }

        var previous: NSWindow? = anchor?.isVisible == true ? anchor : nil
        for controller in controllers {
            guard let window = controller.window else { continue }
            if let frame { window.setFrame(frame, display: false) }
            if let previous, window.tabbingMode != .disallowed,
               previous.addTabbedWindowSafely(window, ordered: .above) {
                // Joined the tab group right after the previous one.
            } else {
                window.orderFront(nil)
            }
            previous = window
        }

        let target = workspace.selectedTab.flatMap { workspace.contains($0) ? $0 : nil } ?? first
        target.window?.makeKeyAndOrderFront(nil)
    }

    /// Take a workspace's windows off screen without closing them.
    fileprivate func hide(_ workspace: TerminalWorkspace) {
        for controller in workspace.controllers {
            guard let window = controller.window else { continue }
            window.tabGroup?.removeWindow(window)
            window.orderOut(nil)
        }
    }
}

// MARK: Restoration

extension TerminalWorkspaceGroup {
    /// Groups being rebuilt by window restoration, by their saved id.
    private static var restoring: [UUID: TerminalWorkspaceGroup] = [:]
    private static var restoreFinish: DispatchWorkItem?

    /// Put a restored window back into the workspace it was saved in.
    ///
    /// AppKit restores windows one at a time and re-tabs them itself, so
    /// this collects the windows of a group as they arrive and, once they
    /// stop arriving, hides every workspace but the selected one.
    static func restore(
        _ controller: TerminalController,
        groupID: UUID,
        workspaceID: UUID,
        name: String?,
        index: Int?,
        selected: Bool,
        sidebarCollapsed: Bool,
        hidden: [TerminalRestorableState.HiddenWorkspace<Ghostty.SurfaceView>],
        ghostty: Ghostty.App
    ) {
        let group: TerminalWorkspaceGroup
        if let existing = restoring[groupID] {
            group = existing
            let workspace = group.workspace(id: workspaceID)
                ?? group.makeWorkspace(named: name, id: workspaceID)
            group.add(controller, to: workspace)
        } else {
            group = TerminalWorkspaceGroup(initial: controller, id: groupID)
            let first = TerminalWorkspace(name: name ?? group.selected.name, id: workspaceID)
            first.append(controller)
            first.selectedTab = controller
            group.workspaces = [first]
            group.selectedID = workspaceID
            restoring[groupID] = group
        }

        group.isSidebarCollapsed = sidebarCollapsed
        if let index { group.restoredIndices[workspaceID] = index }
        if selected { group.restoredSelectedID = workspaceID }

        // AppKit never saw the hidden workspaces' windows, so the first
        // restored tab of the group recreates them off screen.
        if !group.didRestoreHidden {
            group.didRestoreHidden = true
            for saved in hidden {
                let workspace = group.workspace(id: saved.id)
                    ?? group.makeWorkspace(named: saved.name, id: saved.id)
                group.restoredIndices[saved.id] = saved.index
                for tab in saved.tabs where !tab.surfaceTree.isEmpty {
                    let restored = TerminalController(ghostty, withSurfaceTree: tab.surfaceTree)
                    guard let window = restored.window else { continue }
                    if let tabColor = tab.tabColor {
                        (window as? TerminalWindow)?.tabColor = tabColor
                    }
                    restored.titleOverride = tab.titleOverride
                    if let focusedStr = tab.focusedSurface,
                       let view = restored.surfaceTree.first(where: { $0.id.uuidString == focusedStr }) {
                        restored.focusedSurface = view
                    }
                    group.add(restored, to: workspace)
                    if workspace.selectedTab == nil { workspace.selectedTab = restored }
                }
            }
        }

        restoreFinish?.cancel()
        let work = DispatchWorkItem { finishRestoring() }
        restoreFinish = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500), execute: work)
    }

    private static func finishRestoring() {
        for group in restoring.values {
            group.finishRestoring()
        }
        restoring.removeAll()
    }

    private func finishRestoring() {
        // Sidebar order as it was saved.
        workspaces.sort { lhs, rhs in
            (restoredIndices[lhs.id] ?? Int.max) < (restoredIndices[rhs.id] ?? Int.max)
        }

        // The workspace to show is the saved selection, but only if AppKit
        // actually put one of its windows on screen; otherwise whichever
        // workspace has a visible window wins. Saved state can be stale.
        func isOnScreen(_ workspace: TerminalWorkspace) -> Bool {
            workspace.controllers.contains { $0.window?.isVisible ?? false }
        }
        let target = restoredSelectedID.flatMap { workspace(id: $0) }.flatMap { isOnScreen($0) ? $0 : nil }
            ?? workspaces.first(where: isOnScreen)
            ?? selected
        selectedID = target.id
        for workspace in workspaces where workspace !== target {
            hide(workspace)
        }

        // Make sure the visible workspace is one tab group, since AppKit
        // only re-tabs windows it restored together.
        let visible = target.controllers.compactMap(\.window)
        if let first = visible.first {
            for window in visible.dropFirst() where window.tabGroup !== first.tabGroup {
                first.addTabbedWindowSafely(window, ordered: .above)
            }
        }

        // If nothing of the target is on screen (every restored window was
        // hidden state), show it so the window doesn't vanish.
        if !isOnScreen(target) {
            reveal(target, anchor: nil, frame: lastFrame ?? visible.first?.frame)
        }

        restoredIndices.removeAll()
        restoredSelectedID = nil
        syncVisibleTabs()
    }
}
