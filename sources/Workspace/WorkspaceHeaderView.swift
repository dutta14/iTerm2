//
//  WorkspaceHeaderView.swift
//  iTerm2SharedARC
//
//  The 44 pt bar above the terminal column: repo crumb, branch pill and session title.
//

import AppKit

final class WorkspaceHeaderView: NSView {
    struct Content: Equatable {
        var repo: String?
        var branch: String?
        var title: String
        var viewName: String?
        var inspectorVisible = false
        var inspectorAvailable = true
        var prNumber: Int?
    }

    var onToggleSidebar: (() -> Void)?
    var onBack: (() -> Void)?
    var onToggleInspector: (() -> Void)?
    var onViewPR: (() -> Void)?

    private let repoLabel = NSTextField(labelWithString: "")
    private let slashLabel = NSTextField(labelWithString: "/")
    private let pill = NSView()
    private let pillIcon = NSImageView()
    private let pillLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let reopenButton = NSButton()
    private let backButton = NSButton()
    private let inspectorButton = NSButton()
    private let viewPRButton = NSButton()
    private let bottomBorder = NSView()
    private var content = Content(repo: nil, branch: nil, title: "")
    private var sidebarCollapsed = false

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityRole(.group)

        repoLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        repoLabel.textColor = WorkspaceColor.textSecondary
        repoLabel.lineBreakMode = .byTruncatingMiddle
        slashLabel.font = .systemFont(ofSize: 12.5)
        slashLabel.textColor = WorkspaceColor.textSecondary
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = WorkspaceColor.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail

        pill.wantsLayer = true
        pill.layer?.cornerRadius = 8
        pillIcon.image = NSImage(systemSymbolName: SFSymbol.arrowTrianglePull.rawValue, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        pillLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        pillLabel.lineBreakMode = .byTruncatingTail
        pill.addSubview(pillIcon)
        pill.addSubview(pillLabel)

        reopenButton.isBordered = false
        reopenButton.image = NSImage(systemSymbolName: SFSymbol.sidebarLeft.rawValue, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        reopenButton.imagePosition = .imageOnly
        reopenButton.contentTintColor = WorkspaceColor.textSecondary
        reopenButton.toolTip = String(localized: "Workspace.Sidebar.Toggle.Show",
                                      defaultValue: "Show sidebar (⌘B)",
                                      comment: "Tooltip when the sidebar is closed. The shortcut is Command-B.")
        reopenButton.setAccessibilityLabel(reopenButton.toolTip)
        reopenButton.target = self
        reopenButton.action = #selector(reopenClicked)
        backButton.isBordered = false
        backButton.title = String(localized: "Workspace.View.BackToSession",
                                  defaultValue: "Back to session",
                                  comment: "Button in the header of a full-window view that returns to the terminal session")
        backButton.image = NSImage(systemSymbolName: SFSymbol.chevronLeft.rawValue, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        backButton.imagePosition = .imageLeading
        backButton.font = .systemFont(ofSize: 13)
        backButton.contentTintColor = WorkspaceColor.accentText
        backButton.target = self
        backButton.action = #selector(backClicked)
        backButton.toolTip = String(localized: "Workspace.View.BackToSession.Tooltip",
                                    defaultValue: "Back to session (Esc)",
                                    comment: "Tooltip of the button that returns from a full-window view to the terminal session. Esc is the Escape key.")
        backButton.isHidden = true
        inspectorButton.isBordered = false
        inspectorButton.image = NSImage(systemSymbolName: SFSymbol.sidebarRight.rawValue, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        inspectorButton.imagePosition = .imageOnly
        inspectorButton.contentTintColor = WorkspaceColor.textSecondary
        inspectorButton.target = self
        inspectorButton.action = #selector(inspectorClicked)
        viewPRButton.isBordered = false
        viewPRButton.attributedTitle = NSAttributedString(string: String(localized: "Workspace.Header.ViewPR.Label", defaultValue: "View PR", comment: "Header button that opens the session's pull request in the inspector"),
                                                          attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: WorkspaceColor.accentText])
        viewPRButton.toolTip = String(localized: "Workspace.Header.ViewPR.Tooltip", defaultValue: "Show this pull request in the inspector", comment: "Tooltip of the View PR button in the header")
        viewPRButton.setAccessibilityLabel(viewPRButton.toolTip)
        viewPRButton.target = self
        viewPRButton.action = #selector(viewPRClicked)
        viewPRButton.isHidden = true
        bottomBorder.wantsLayer = true

        [repoLabel, slashLabel, pill, titleLabel, reopenButton, backButton, inspectorButton, viewPRButton, bottomBorder].forEach(addSubview)
        updateInspectorButton()
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) has not been implemented")
    }

    func update(content: Content, sidebarCollapsed: Bool) {
        guard content != self.content || sidebarCollapsed != self.sidebarCollapsed else { return }
        self.content = content
        self.sidebarCollapsed = sidebarCollapsed
        needsLayout = true
        updateInspectorButton()
        setAccessibilityLabel(content.title)
    }

    @objc private func reopenClicked() { onToggleSidebar?() }
    @objc private func backClicked() { onBack?() }
    @objc private func inspectorClicked() { onToggleInspector?() }
    @objc private func viewPRClicked() { onViewPR?() }

    private func updateInspectorButton() {
        inspectorButton.isHidden = content.viewName != nil
        let shortcut = "⌥⌘\\"
        inspectorButton.toolTip = content.inspectorVisible
            ? String(localized: "Workspace.Header.Inspector.Hide", defaultValue: "Hide inspector (\(shortcut))", comment: "Tooltip when the inspector is open. The placeholder is the keyboard shortcut Option-Command-Backslash.")
            : String(localized: "Workspace.Header.Inspector.Show", defaultValue: "Show inspector (\(shortcut))", comment: "Tooltip when the inspector is closed. The placeholder is the keyboard shortcut Option-Command-Backslash.")
        inspectorButton.setAccessibilityLabel(inspectorButton.toolTip)
        inspectorButton.contentTintColor = content.inspectorVisible ? WorkspaceColor.accentText : WorkspaceColor.textSecondary
        inspectorButton.isEnabled = content.inspectorAvailable
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = WorkspaceColor.windowBackground.cgColor
            bottomBorder.layer?.backgroundColor = WorkspaceColor.separator.cgColor
            pill.layer?.backgroundColor = WorkspaceColor.accent.cgColor
        }
        pillIcon.contentTintColor = WorkspaceColor.onAccent
        pillLabel.textColor = WorkspaceColor.onAccent
        bottomBorder.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)

        var x: CGFloat = 16
        reopenButton.isHidden = !sidebarCollapsed
        if sidebarCollapsed {
            x = 90
            reopenButton.frame = NSRect(x: 76 + 0, y: 8, width: 24, height: 28)
            x = 112
        }

        backButton.isHidden = content.viewName == nil
        if let viewName = content.viewName {
            repoLabel.isHidden = true
            slashLabel.isHidden = true
            pill.isHidden = true
            backButton.frame = NSRect(x: x, y: 8, width: 130, height: 28)
            x += 142
            titleLabel.stringValue = viewName
            titleLabel.frame = NSRect(x: x, y: 13, width: max(0, bounds.width - x - 16), height: 18)
            titleLabel.isHidden = false
            return
        }

        inspectorButton.frame = NSRect(x: bounds.width - 40, y: 8, width: 28, height: 28)
        var trailing = bounds.width - 48
        viewPRButton.isHidden = content.prNumber == nil
        if content.prNumber != nil {
            let width = ceil(viewPRButton.intrinsicContentSize.width)
            viewPRButton.frame = NSRect(x: trailing - width, y: 8, width: width, height: 28)
            trailing -= width + 12
        }
        let repoText = content.repo ?? ""
        repoLabel.isHidden = repoText.isEmpty
        slashLabel.isHidden = repoText.isEmpty
        repoLabel.stringValue = repoText
        if !repoText.isEmpty {
            let width = min(repoLabel.intrinsicContentSize.width, max(0, (trailing - x) * 0.4))
            repoLabel.frame = NSRect(x: x, y: 14, width: width, height: 16)
            x += width + 6
            slashLabel.frame = NSRect(x: x, y: 14, width: 8, height: 16)
            x += 14
        }

        let branch = content.branch ?? ""
        pill.isHidden = branch.isEmpty
        if !branch.isEmpty {
            pillLabel.stringValue = branch
            let labelWidth = min(pillLabel.intrinsicContentSize.width, max(56, (trailing - x) * 0.35))
            let pillWidth = 10 + 14 + 6 + labelWidth + 10
            pill.frame = NSRect(x: x, y: 8, width: pillWidth, height: 28)
            pillIcon.frame = NSRect(x: 10, y: 7, width: 14, height: 14)
            pillLabel.frame = NSRect(x: 30, y: 6, width: labelWidth, height: 16)
            x += pillWidth + 10
        }

        titleLabel.stringValue = content.title
        titleLabel.frame = NSRect(x: x, y: 13, width: max(0, trailing - x), height: 18)
        titleLabel.isHidden = trailing - x < 24
    }
}
