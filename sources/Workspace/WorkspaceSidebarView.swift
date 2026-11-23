//
//  WorkspaceSidebarView.swift
//  iTerm2SharedARC
//
//  Left sidebar of the workspace window: navigation rows, sessions grouped by repo, and a
//  profile row. Rows are laid out by hand because the window's layout is calculator-driven.
//

import AppKit

enum WorkspaceNavItem: CaseIterable {
    case newSession
    case pullRequests
    case issues
    case automations

    var title: String {
        switch self {
        case .newSession:
            return String(localized: "Workspace.Sidebar.Nav.New", defaultValue: "New session",
                          comment: "Sidebar row that starts a session.")
        case .pullRequests:
            return String(localized: "Workspace.Sidebar.Nav.PullRequests", defaultValue: "Pull requests",
                          comment: "Sidebar row that shows pull requests.")
        case .issues:
            return String(localized: "Workspace.Sidebar.Nav.Issues", defaultValue: "Issues",
                          comment: "Sidebar row that shows issues.")
        case .automations:
            return String(localized: "Workspace.Sidebar.Nav.Automations", defaultValue: "Automations",
                          comment: "Sidebar row that shows GitHub Actions runs.")
        }
    }

    var symbol: SFSymbol {
        switch self {
        case .newSession: return .squareAndPencil
        case .pullRequests: return .arrowTrianglePull
        case .issues: return .circleDotted
        case .automations: return .bolt
        }
    }
}

protocol WorkspaceSidebarDelegate: AnyObject {
    func sidebarDidRequestToggle(_ sidebar: WorkspaceSidebarView)
    func sidebarDidRequestSearch(_ sidebar: WorkspaceSidebarView)
    func sidebar(_ sidebar: WorkspaceSidebarView, didSelectNav item: WorkspaceNavItem)
    func sidebar(_ sidebar: WorkspaceSidebarView, didSelectSession record: WorkspaceSessionRecord)
    func sidebar(_ sidebar: WorkspaceSidebarView, didRequestNewSessionInRepo repo: String?)
    func sidebarDidRequestSettings(_ sidebar: WorkspaceSidebarView)
}

private func symbolImage(_ symbol: SFSymbol, pointSize: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight, scale: .medium)
    return NSImage(systemSymbolName: symbol.rawValue, accessibilityDescription: nil)?
        .withSymbolConfiguration(config)
}

/// A flipped container that tracks hover and reports clicks.
private final class WorkspaceRowView: NSView {
    var onClick: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var isSelected = false { didSet { updateBackground() } }
    private(set) var isHovered = false { didSet { updateBackground(); onHoverChanged?(isHovered) } }
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func viewDidChangeEffectiveAppearance() {
        updateBackground()
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color: NSColor? = isSelected ? WorkspaceColor.selectedFill
                : (isHovered ? WorkspaceColor.hoverFill : nil)
            layer?.backgroundColor = color?.cgColor
        }
    }
}

final class WorkspaceSidebarView: NSVisualEffectView {
    weak var delegate: WorkspaceSidebarDelegate?

    static let titleStripHeight: CGFloat = 44
    private static let profileRowHeight: CGFloat = 44
    private static let horizontalInset: CGFloat = 8

    private var toggleButton: NSButton!
    private var searchButton: NSButton!
    private let scrollView = NSScrollView()
    private let documentView = FlippedView()
    private let profileRow = NSView()
    private let separator = NSView()
    private var collapsedRepos = Set<String>()
    private var groups: [WorkspaceRepoGroup] = []
    private var selectedRecordId: String?
    private var activeNav: WorkspaceNavItem?

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .sidebar
        blendingMode = .behindWindow
        state = .followsWindowActiveState
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Workspace.Sidebar.A11y.Label",
                                     defaultValue: "Sessions sidebar",
                                     comment: "Accessibility label of the sidebar region."))
        configureTitleStrip()
        configureScrollView()
        configureProfileRow()
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func makeIconButton(_ symbol: SFSymbol, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.image = symbolImage(symbol, pointSize: 13)
        button.imagePosition = .imageOnly
        button.contentTintColor = WorkspaceColor.textSecondary
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.target = self
        button.action = action
        return button
    }

    private func configureTitleStrip() {
        let hide = String(localized: "Workspace.Sidebar.Toggle.Hide", defaultValue: "Hide sidebar (⌘B)",
                          comment: "Tooltip when the sidebar is open. The shortcut is Command-B.")
        let toggle = makeIconButton(.sidebarLeft, tooltip: hide, action: #selector(toggleClicked))
        let search = makeIconButton(.magnifyingglass,
                                    tooltip: String(localized: "Workspace.Sidebar.Search.Tooltip",
                                                    defaultValue: "Search sessions (⌘⇧O)",
                                                    comment: "Tooltip of the search button. The shortcut is Command-Shift-O."),
                                    action: #selector(searchClicked))
        addSubview(toggle)
        addSubview(search)
        toggleButton = toggle
        searchButton = search
    }

    private func configureScrollView() {
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.documentView = documentView
        addSubview(scrollView)
    }

    private func configureProfileRow() {
        profileRow.wantsLayer = true
        addSubview(profileRow)
        separator.wantsLayer = true
        addSubview(separator)

        let avatar = NSView(frame: NSRect(x: 12, y: 10, width: 24, height: 24))
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = 12
        let gradient = CAGradientLayer()
        gradient.colors = [NSColor(srgbRed: 0xA7 / 255, green: 0x8B / 255, blue: 0xFA / 255, alpha: 1).cgColor,
                           NSColor(srgbRed: 0x60 / 255, green: 0xA5 / 255, blue: 0xFA / 255, alpha: 1).cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        gradient.frame = avatar.bounds
        avatar.layer?.addSublayer(gradient)
        profileRow.addSubview(avatar)

        let name = NSTextField(labelWithString: NSFullUserName())
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.textColor = WorkspaceColor.textPrimary
        name.lineBreakMode = .byTruncatingTail
        name.tag = 1
        profileRow.addSubview(name)

        let gear = makeIconButton(.gearshape,
                                  tooltip: String(localized: "Workspace.Sidebar.Profile.GearTooltip",
                                                  defaultValue: "Workspace settings",
                                                  comment: "Tooltip of the gear button next to the profile name."),
                                  action: #selector(settingsClicked))
        gear.tag = 2
        profileRow.addSubview(gear)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let width = bounds.width
        toggleButton.frame = NSRect(x: 76, y: bounds.height - 36, width: 24, height: 28)
        searchButton.frame = NSRect(x: 100, y: bounds.height - 36, width: 24, height: 28)

        let profileHeight = Self.profileRowHeight
        profileRow.frame = NSRect(x: 0, y: 0, width: width, height: profileHeight)
        separator.frame = NSRect(x: 0, y: profileHeight, width: width, height: 1 / max(1, window?.backingScaleFactor ?? 2))
        separator.layer?.backgroundColor = WorkspaceColor.separator.cgColor
        if let name = profileRow.viewWithTag(1) {
            name.frame = NSRect(x: 44, y: 13, width: max(0, width - 44 - 40), height: 18)
        }
        if let gear = profileRow.viewWithTag(2) {
            gear.frame = NSRect(x: width - 36, y: 8, width: 28, height: 28)
        }

        let scrollTop = Self.titleStripHeight
        scrollView.frame = NSRect(x: 0,
                                  y: profileHeight + 1,
                                  width: width,
                                  height: max(0, bounds.height - scrollTop - profileHeight - 1))
        rebuildDocument()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    // MARK: - Content

    func update(groups: [WorkspaceRepoGroup], selectedRecordId: String?, activeNav: WorkspaceNavItem?) {
        self.groups = groups
        self.selectedRecordId = selectedRecordId
        self.activeNav = activeNav
        rebuildDocument()
    }

    private func rebuildDocument() {
        documentView.subviews.forEach { $0.removeFromSuperview() }
        let width = scrollView.bounds.width
        guard width > 0 else { return }
        var y: CGFloat = 4

        for item in WorkspaceNavItem.allCases {
            documentView.addSubview(makeNavRow(item, y: y, width: width))
            y += 32
        }
        y += 8
        documentView.addSubview(makeSectionHeader(y: y, width: width))
        y += 28

        if groups.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: String(
                localized: "Workspace.Sidebar.Empty.Body",
                defaultValue: "Start one in a repo and it shows up here.",
                comment: "Body of the empty sidebar."))
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = WorkspaceColor.textSecondary
            empty.frame = NSRect(x: 18, y: y + 4, width: max(0, width - 36), height: 32)
            documentView.addSubview(empty)
            y += 40
        }

        for group in groups {
            let key = group.repo ?? ""
            documentView.addSubview(makeGroupHeader(group, y: y, width: width))
            y += 28
            if !collapsedRepos.contains(key) {
                for record in group.sessions {
                    documentView.addSubview(makeSessionRow(record, y: y, width: width))
                    y += 30
                }
            }
        }
        documentView.frame = NSRect(x: 0, y: 0, width: width, height: max(y + 8, scrollView.bounds.height))
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        return field
    }

    private func makeNavRow(_ item: WorkspaceNavItem, y: CGFloat, width: CGFloat) -> NSView {
        let row = WorkspaceRowView(frame: NSRect(x: Self.horizontalInset, y: y,
                                                 width: width - 2 * Self.horizontalInset, height: 32))
        row.isSelected = (item == activeNav)
        let icon = NSImageView(frame: NSRect(x: 10, y: 8, width: 16, height: 16))
        icon.image = symbolImage(item.symbol, pointSize: 13)
        icon.contentTintColor = WorkspaceColor.textSecondary
        row.addSubview(icon)
        let title = label(item.title, size: 13, weight: .medium, color: WorkspaceColor.textPrimary)
        title.frame = NSRect(x: 36, y: 7, width: max(0, row.bounds.width - 46), height: 18)
        row.addSubview(title)
        row.setAccessibilityLabel(item.title)
        row.onClick = { [weak self] in
            guard let self else { return }
            self.delegate?.sidebar(self, didSelectNav: item)
        }
        return row
    }

    private func makeSectionHeader(y: CGFloat, width: CGFloat) -> NSView {
        let header = NSView(frame: NSRect(x: Self.horizontalInset, y: y,
                                          width: width - 2 * Self.horizontalInset, height: 28))
        let title = label(String(localized: "Workspace.Sidebar.SessionsHeader", defaultValue: "Sessions",
                                 comment: "Section header above the session list."),
                          size: 12.5, weight: .regular, color: WorkspaceColor.textSecondary)
        title.frame = NSRect(x: 10, y: 6, width: max(0, header.bounds.width - 50), height: 16)
        header.addSubview(title)
        let plus = makeIconButton(.plus,
                                  tooltip: String(localized: "Workspace.Sidebar.Section.NewTooltip",
                                                  defaultValue: "Choose a repo for a new session",
                                                  comment: "Tooltip of the plus on the Sessions header."),
                                  action: #selector(sectionPlusClicked))
        plus.frame = NSRect(x: header.bounds.width - 30, y: 0, width: 28, height: 28)
        header.addSubview(plus)
        return header
    }

    private func makeGroupHeader(_ group: WorkspaceRepoGroup, y: CGFloat, width: CGFloat) -> NSView {
        let key = group.repo ?? ""
        let row = WorkspaceRowView(frame: NSRect(x: Self.horizontalInset, y: y,
                                                 width: width - 2 * Self.horizontalInset, height: 28))
        let collapsed = collapsedRepos.contains(key)
        let chevron = NSImageView(frame: NSRect(x: 8, y: 8, width: 12, height: 12))
        chevron.image = symbolImage(collapsed ? .chevronRight : .chevronDown, pointSize: 10, weight: .semibold)
        chevron.contentTintColor = WorkspaceColor.textSecondary
        row.addSubview(chevron)

        let name = group.repo ?? String(localized: "Workspace.Sidebar.NoRepo.Label",
                                        defaultValue: "No repository",
                                        comment: "Group label for sessions with no resolved repo.")
        let title = label(name, size: 12.5, weight: .medium, color: WorkspaceColor.textPrimary)
        title.lineBreakMode = .byTruncatingMiddle
        title.frame = NSRect(x: 26, y: 5, width: max(0, row.bounds.width - 26 - 34), height: 16)
        row.addSubview(title)
        row.setAccessibilityLabel(name)
        row.setAccessibilityValue(collapsed ? "collapsed" : "expanded")

        if let repo = group.repo {
            let tip = String(format: String(localized: "Workspace.Sidebar.Group.NewTooltip",
                                            defaultValue: "New session in %@",
                                            comment: "Tooltip of the plus on a repo group. %@ is the repo name."),
                             repo)
            let plus = makeIconButton(.plus, tooltip: tip, action: #selector(groupPlusClicked(_:)))
            plus.identifier = NSUserInterfaceItemIdentifier(repo)
            plus.frame = NSRect(x: row.bounds.width - 30, y: 0, width: 28, height: 28)
            plus.alphaValue = 0
            row.addSubview(plus)
            row.onHoverChanged = { hovering in plus.alphaValue = hovering ? 1 : 0 }
        } else {
            row.toolTip = String(localized: "Workspace.Sidebar.NoRepo.Tooltip",
                                 defaultValue: "Sessions without a repo.",
                                 comment: "Tooltip on the No repository group.")
        }
        row.onClick = { [weak self] in
            guard let self else { return }
            if self.collapsedRepos.contains(key) {
                self.collapsedRepos.remove(key)
            } else {
                self.collapsedRepos.insert(key)
            }
            self.rebuildDocument()
        }
        return row
    }

    private func makeSessionRow(_ record: WorkspaceSessionRecord, y: CGFloat, width: CGFloat) -> NSView {
        let row = WorkspaceRowView(frame: NSRect(x: Self.horizontalInset, y: y,
                                                 width: width - 2 * Self.horizontalInset, height: 30))
        row.isSelected = (record.id == selectedRecordId)
        let icon = NSImageView(frame: NSRect(x: 22, y: 8, width: 14, height: 14))
        let statusSymbol: SFSymbol
        let tint: NSColor
        let statusText: String
        switch record.status {
        case .running:
            statusSymbol = .arrowTriangle2Circlepath
            tint = WorkspaceColor.accent
            statusText = String(localized: "Workspace.Sidebar.Status.Running", defaultValue: "Running",
                                comment: "Status of a session that is running.")
        case .done:
            statusSymbol = .checkmarkCircle
            tint = WorkspaceColor.success
            statusText = String(localized: "Workspace.Sidebar.Status.Done", defaultValue: "Done",
                                comment: "Status of a session that has finished.")
        case .errored:
            statusSymbol = .exclamationmarkCircle
            tint = WorkspaceColor.danger
            statusText = String(localized: "Workspace.Sidebar.Status.Errored", defaultValue: "Ended with error",
                                comment: "Status of a session whose process exited with an error.")
        }
        icon.image = symbolImage(statusSymbol, pointSize: 11)
        icon.contentTintColor = tint
        icon.toolTip = statusText
        row.addSubview(icon)

        let title = label(record.title, size: 13, weight: .regular, color: WorkspaceColor.textPrimary)
        title.frame = NSRect(x: 44, y: 6, width: max(0, row.bounds.width - 54), height: 18)
        row.addSubview(title)
        row.setAccessibilityLabel("\(record.title), \(statusText)")
        row.onClick = { [weak self] in
            guard let self else { return }
            self.delegate?.sidebar(self, didSelectSession: record)
        }
        return row
    }

    // MARK: - Actions

    func setToggleTooltip(visible: Bool) {
        toggleButton.toolTip = visible
            ? String(localized: "Workspace.Sidebar.Toggle.Hide", defaultValue: "Hide sidebar (⌘B)",
                     comment: "Tooltip when the sidebar is open. The shortcut is Command-B.")
            : String(localized: "Workspace.Sidebar.Toggle.Show", defaultValue: "Show sidebar (⌘B)",
                     comment: "Tooltip when the sidebar is closed. The shortcut is Command-B.")
    }

    @objc private func toggleClicked() { delegate?.sidebarDidRequestToggle(self) }
    @objc private func searchClicked() { delegate?.sidebarDidRequestSearch(self) }
    @objc private func settingsClicked() { delegate?.sidebarDidRequestSettings(self) }
    @objc private func sectionPlusClicked() { delegate?.sidebar(self, didRequestNewSessionInRepo: nil) }
    @objc private func groupPlusClicked(_ sender: NSButton) {
        delegate?.sidebar(self, didRequestNewSessionInRepo: sender.identifier?.rawValue)
    }
}
