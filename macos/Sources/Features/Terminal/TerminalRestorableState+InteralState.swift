import AppKit

extension TerminalRestorableState {
    /// Internal State we use to perform unit tests
    ///
    /// Since we can't really change the type of `TerminalRestorableState`
    /// due to `CodableBridge<TerminalRestorableState>` supporting secure coding,
    /// we use an internal type to perform migration and tests
    struct InternalState<ViewType: NSView & Codable & Identifiable>: Codable {
        // MARK: - Version 5 (1.2.3)
        let focusedSurface: String?
        let surfaceTree: SplitTree<ViewType>

        // MARK: - Version 7 (1.3.0)
        let effectiveFullscreenMode: FullscreenMode?
        let tabColor: TerminalTabColor?
        let titleOverride: String?

        // MARK: - Version 8 (workspaces)
        let workspaceGroupID: UUID?
        let workspaceID: UUID?
        let workspaceName: String?
        let workspaceIndex: Int?
        let workspaceSelected: Bool?
        let workspaceSidebarCollapsed: Bool?
        let workspaceIcon: String?
        let workspaceColor: TerminalTabColor?

        /// The workspaces of the window that are not on screen. AppKit only
        /// persists visible windows, so every visible tab carries the hidden
        /// workspaces of its window and the first tab restored recreates them.
        let hiddenWorkspaces: [TerminalRestorableState.HiddenWorkspace<ViewType>]?
    }

    /// A workspace whose tabs were hidden when the state was saved.
    struct HiddenWorkspace<ViewType: NSView & Codable & Identifiable>: Codable {
        let id: UUID
        let name: String
        let index: Int
        let tabs: [TerminalRestorableState.HiddenTab<ViewType>]
        let icon: String?
        let color: TerminalTabColor?
    }

    /// One tab of a hidden workspace: what a window needs to come back.
    struct HiddenTab<ViewType: NSView & Codable & Identifiable>: Codable {
        let focusedSurface: String?
        let surfaceTree: SplitTree<ViewType>
        let tabColor: TerminalTabColor?
        let titleOverride: String?
    }
}

extension TerminalRestorableState.InternalState where ViewType == Ghostty.SurfaceView {
    init(from controller: TerminalController) {
        self.init(
            focusedSurface: controller.focusedSurface?.id.uuidString,
            surfaceTree: controller.surfaceTree,
            effectiveFullscreenMode: controller.fullscreenStyle?.fullscreenMode,
            tabColor: (controller.window as? TerminalWindow)?.tabColor,
            titleOverride: controller.titleOverride,
            workspaceGroupID: controller.workspaceGroup?.id,
            workspaceID: controller.workspaceGroup?.workspace(containing: controller)?.id,
            workspaceName: controller.workspaceGroup?.workspace(containing: controller)?.name,
            workspaceIndex: controller.workspaceGroup.flatMap { group in
                group.workspaces.firstIndex { $0.contains(controller) }
            },
            workspaceSelected: controller.workspaceGroup.map { group in
                group.selected.contains(controller)
            },
            workspaceSidebarCollapsed: controller.workspaceGroup?.isSidebarCollapsed,
            workspaceIcon: controller.workspaceGroup?.workspace(containing: controller)?.icon,
            workspaceColor: controller.workspaceGroup?.workspace(containing: controller)?.color,
            hiddenWorkspaces: controller.workspaceGroup.map { group in
                group.workspaces.enumerated()
                    .filter { $0.element.id != group.selectedID }
                    .map { index, workspace in
                        TerminalRestorableState.HiddenWorkspace(
                            id: workspace.id,
                            name: workspace.name,
                            index: index,
                            tabs: workspace.controllers.map { tab in
                                TerminalRestorableState.HiddenTab(
                                    focusedSurface: tab.focusedSurface?.id.uuidString,
                                    surfaceTree: tab.surfaceTree,
                                    tabColor: (tab.window as? TerminalWindow)?.tabColor,
                                    titleOverride: tab.titleOverride)
                            },
                            icon: workspace.icon,
                            color: workspace.color)
                    }
            },
        )
    }
}
