//
//  WorkspaceMenu.swift
//  iTerm2SharedARC
//
//  The Workspace menu. It exists only while the workspace UI is on (AC-008). The shortcuts are
//  handled by WorkspaceController's key monitor; the key equivalents here make them discoverable.
//

import AppKit

@objc(iTermWorkspaceMenu)
final class WorkspaceMenu: NSObject, NSMenuItemValidation {
    private static let shared = WorkspaceMenu()
    private static var installed = false

    static func installIfNeeded() {
        guard !installed, WorkspaceSettings.isEnabled, let mainMenu = NSApp.mainMenu else { return }
        installed = true
        let title = String(localized: "Workspace.Menu.Title", defaultValue: "Workspace", comment: "Title of the Workspace menu in the menu bar")
        let menu = NSMenu(title: title)
        let shared = Self.shared
        func add(_ title: String, _ action: Selector, _ key: String = "", _ flags: NSEvent.ModifierFlags = []) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = flags
            item.target = shared
            menu.addItem(item)
        }
        add(String(localized: "Workspace.Menu.ToggleSidebar", defaultValue: "Show or Hide Sidebar", comment: "Workspace menu item"), #selector(toggleSidebar), "b", .command)
        add(String(localized: "Workspace.Menu.ToggleInspector", defaultValue: "Show or Hide Inspector", comment: "Workspace menu item"), #selector(toggleInspector), "\\", [.option, .command])
        menu.addItem(.separator())
        add(String(localized: "Workspace.Menu.Changes", defaultValue: "Show Changes", comment: "Workspace menu item"), #selector(showChanges), "\\", .command)
        add(String(localized: "Workspace.Menu.Terminal", defaultValue: "Show Terminal Tab", comment: "Workspace menu item"), #selector(showTerminal), "`", .control)
        add(String(localized: "Workspace.Menu.Files", defaultValue: "Show Files", comment: "Workspace menu item"), #selector(showFiles))
        add(String(localized: "Workspace.Menu.FocusInspector", defaultValue: "Focus Inspector", comment: "Workspace menu item"), #selector(focusInspector), "i", [.command, .control])
        menu.addItem(.separator())
        add(String(localized: "Workspace.Menu.Minimap", defaultValue: "Show Minimap", comment: "Workspace menu item that toggles the prompt minimap"), #selector(toggleMinimap))
        add(String(localized: "Workspace.Menu.ResetLayout", defaultValue: "Reset Layout…", comment: "Workspace menu item"), #selector(resetLayout))

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        let windowIndex = mainMenu.items.firstIndex { $0.submenu === NSApp.windowsMenu } ?? max(0, mainMenu.items.count - 1)
        mainMenu.insertItem(item, at: windowIndex)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleMinimap) {
            menuItem.state = WorkspaceSettings.minimapEnabled ? .on : .off
            return true
        }
        return WorkspaceController.current != nil
    }

    @objc private func toggleSidebar() { WorkspaceController.current?.toggleSidebar() }
    @objc private func toggleInspector() { WorkspaceController.current?.toggleInspector() }
    @objc private func showChanges() { WorkspaceController.current?.showInspectorTab(.changes) }
    @objc private func showTerminal() { WorkspaceController.current?.showInspectorTab(.terminal) }
    @objc private func showFiles() { WorkspaceController.current?.showInspectorTab(.files) }
    @objc private func focusInspector() { WorkspaceController.current?.focusInspectorFromMenu() }
    @objc private func toggleMinimap() { WorkspaceSettings.minimapEnabled.toggle() }
    @objc private func resetLayout() { WorkspaceController.current?.resetLayout() }
}
