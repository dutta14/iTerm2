//
//  WorkspaceAppearance.swift
//  iTerm2SharedARC
//
//  Semantic colors and appearance mode for the workspace chrome (sidebar, header,
//  inspector). The terminal keeps its own profile colors.
//

import AppKit

enum WorkspaceAppearanceMode: String, CaseIterable {
    case system
    case light
    case dark

    /// nil follows the system appearance.
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

@objc(iTermWorkspaceColor)
final class WorkspaceColor: NSObject {
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        return NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua])
            return match == .darkAqua ? dark : light
        }
    }

    private static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255,
                       green: CGFloat((value >> 8) & 0xff) / 255,
                       blue: CGFloat(value & 0xff) / 255,
                       alpha: alpha)
    }

    static let windowBackground = dynamic(light: hex(0xFFFFFF), dark: hex(0x14161A))
    static let sidebarBackground = dynamic(light: hex(0xF6F7F9), dark: hex(0x1A1D22))
    static let separator = dynamic(light: hex(0xE4E6EA), dark: hex(0x2B3037))
    static let textPrimary = dynamic(light: hex(0x1F2328), dark: hex(0xE8EAED))
    static let textSecondary = dynamic(light: hex(0x6B7280), dark: hex(0x9AA1AB))
    static let textSecondaryStrong = dynamic(light: hex(0x565D69), dark: hex(0x9AA1AB))
    static let accent = dynamic(light: hex(0x7C3AED), dark: hex(0xA78BFA))
    static let accentText = dynamic(light: hex(0x6D28D9), dark: hex(0xC4B5FD))
    static let accentSoft = dynamic(light: hex(0xEDE9FE), dark: hex(0xA78BFA, alpha: 0.18))
    static let onAccent = dynamic(light: hex(0xFFFFFF), dark: hex(0x14161A))
    static let success = dynamic(light: hex(0x2E7D32), dark: hex(0x3FB950))
    static let successText = dynamic(light: hex(0x1A7F37), dark: hex(0x56D364))
    static let danger = dynamic(light: hex(0xD1242F), dark: hex(0xF85149))
    static let warning = dynamic(light: hex(0xB7791F), dark: hex(0xD29922))
    static let warningText = dynamic(light: hex(0x8A5A00), dark: hex(0xD29922))
    static let hoverFill = dynamic(light: hex(0x0F172A, alpha: 0.06), dark: hex(0xFFFFFF, alpha: 0.07))
    static let selectedFill = dynamic(light: hex(0x0F172A, alpha: 0.08), dark: hex(0xFFFFFF, alpha: 0.10))
    static let chipFill = dynamic(light: hex(0xF1F3F5), dark: hex(0x23272E))
}

/// Persistence for the workspace chrome. Keys are local to this machine.
enum WorkspaceSettings {
    static let defaultSidebarWidth: CGFloat = 224
    static let defaultInspectorWidth: CGFloat = 340
    static let headerHeight: CGFloat = 44
    static let collapseSidebarBelowWindowWidth: CGFloat = 600

    private static let appearanceKey = "NoSyncWorkspaceAppearance"
    private static let sidebarWidthKey = "NoSyncWorkspaceSidebarWidth"
    private static let sidebarVisibleKey = "NoSyncWorkspaceSidebarVisible"
    private static let inspectorWidthKey = "NoSyncWorkspaceInspectorWidth"
    private static let inspectorVisibleKey = "NoSyncWorkspaceInspectorVisible"
    private static let minimapKey = "NoSyncWorkspaceMinimap"
    static let collapseInspectorBelowWindowWidth: CGFloat = 900
    static let minimumTerminalColumnWidth: CGFloat = 320

    static var isEnabled: Bool {
        return iTermAdvancedSettingsModel.workspaceUI()
    }

    static var appearanceMode: WorkspaceAppearanceMode {
        get {
            let raw = iTermUserDefaults.userDefaults().string(forKey: appearanceKey) ?? ""
            return WorkspaceAppearanceMode(rawValue: raw) ?? .system
        }
        set {
            iTermUserDefaults.userDefaults().set(newValue.rawValue, forKey: appearanceKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    static var sidebarWidth: CGFloat {
        get {
            let stored = iTermUserDefaults.userDefaults().double(forKey: sidebarWidthKey)
            return stored > 0 ? CGFloat(stored) : defaultSidebarWidth
        }
        set { iTermUserDefaults.userDefaults().set(Double(newValue), forKey: sidebarWidthKey) }
    }

    static var sidebarVisible: Bool {
        get {
            guard iTermUserDefaults.userDefaults().object(forKey: sidebarVisibleKey) != nil else { return true }
            return iTermUserDefaults.userDefaults().bool(forKey: sidebarVisibleKey)
        }
        set { iTermUserDefaults.userDefaults().set(newValue, forKey: sidebarVisibleKey) }
    }

    static var inspectorWidth: CGFloat {
        get {
            let stored = iTermUserDefaults.userDefaults().double(forKey: inspectorWidthKey)
            return stored > 0 ? CGFloat(stored) : defaultInspectorWidth
        }
        set { iTermUserDefaults.userDefaults().set(Double(newValue), forKey: inspectorWidthKey) }
    }

    static var inspectorVisible: Bool {
        get {
            guard iTermUserDefaults.userDefaults().object(forKey: inspectorVisibleKey) != nil else { return true }
            return iTermUserDefaults.userDefaults().bool(forKey: inspectorVisibleKey)
        }
        set { iTermUserDefaults.userDefaults().set(newValue, forKey: inspectorVisibleKey) }
    }

    static var minimapEnabled: Bool {
        get {
            guard iTermUserDefaults.userDefaults().object(forKey: minimapKey) != nil else { return true }
            return iTermUserDefaults.userDefaults().bool(forKey: minimapKey)
        }
        set {
            iTermUserDefaults.userDefaults().set(newValue, forKey: minimapKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// Returns the sidebar and inspector to their default widths.
    static func resetLayout() {
        let defaults = iTermUserDefaults.userDefaults()
        for key in [sidebarWidthKey, inspectorWidthKey, sidebarVisibleKey, inspectorVisibleKey] {
            defaults.removeObject(forKey: key)
        }
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static let didChangeNotification = Notification.Name("iTermWorkspaceSettingsDidChange")
}
