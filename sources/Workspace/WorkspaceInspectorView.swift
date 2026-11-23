//
//  WorkspaceInspectorView.swift
//  iTerm2SharedARC
//
//  The right-hand column: a tab strip with a "+" menu, an expand control and one pane per tab.
//  The panes show the session that is active in the window.
//

import AppKit

private final class InspectorTabButton: NSView {
    let kind: InspectorTabKind
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    var isActive = false {
        didSet {
            needsDisplay = true
            setAccessibilityValue(isActive ? 1 : 0)
        }
    }
    var onSelect: ((InspectorTabKind) -> Void)?
    var onClose: ((InspectorTabKind) -> Void)?
    var onMove: ((InspectorTabKind, Int) -> Void)?
    private var isHovered = false

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    static func title(for kind: InspectorTabKind) -> String {
        switch kind {
        case .changes: return String(localized: "Workspace.Inspector.Tab.Changes", defaultValue: "Changes", comment: "Inspector tab label")
        case .terminal: return String(localized: "Workspace.Inspector.Tab.Terminal", defaultValue: "Terminal", comment: "Inspector tab label")
        case .files: return String(localized: "Workspace.Inspector.Tab.Files", defaultValue: "Files", comment: "Inspector tab label")
        case .pullRequest: return String(localized: "Workspace.Inspector.Tab.PR.Generic", defaultValue: "Pull request", comment: "Inspector tab label when the pull request number isn't known")
        case .browser: return String(localized: "Workspace.Inspector.Tab.Browser", defaultValue: "Browser", comment: "Inspector tab label. Deferred.")
        case .sideChat: return String(localized: "Workspace.Inspector.Tab.SideChat", defaultValue: "Side chat", comment: "Inspector tab label. Deferred.")
        }
    }

    static func symbol(for kind: InspectorTabKind) -> SFSymbol {
        switch kind {
        case .changes: return .plusSlashMinus
        case .terminal: return .terminal
        case .files: return .folder
        case .pullRequest: return .arrowTrianglePull
        case .browser: return .globe
        case .sideChat: return .bubbleLeft
        }
    }

    init(kind: InspectorTabKind) {
        self.kind = kind
        super.init(frame: .zero)
        let title = Self.title(for: kind)
        iconView.image = workspaceSymbolImage(Self.symbol(for: kind), pointSize: 12, weight: .medium)
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        closeButton.isBordered = false
        closeButton.image = workspaceSymbolImage(.xmark, pointSize: 9, weight: .semibold)
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = WorkspaceColor.textSecondary
        closeButton.toolTip = String(localized: "Workspace.Inspector.CloseTab", defaultValue: "Close tab", comment: "Tooltip of the inspector tab close button")
        closeButton.setAccessibilityLabel(String(localized: "Workspace.Inspector.CloseTab.A11y", defaultValue: "Close \(title)", comment: "VoiceOver label of an inspector tab's close button. The placeholder is the tab name."))
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        [iconView, titleLabel, closeButton].forEach(addSubview)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
        setAccessibilityValue(0)
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) has not been implemented")
    }

    var idealWidth: CGFloat {
        return 12 + 14 + 6 + ceil(titleLabel.intrinsicContentSize.width) + 6 + 18 + 8
    }

    @objc private func closeTapped() {
        onClose?(kind)
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?(kind)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onSelect?(kind)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onMove?(kind, -1)
        case 124: onMove?(kind, 1)
        case 51, 117: onClose?(kind)
        case 36, 49: onSelect?(kind)
        default: super.keyDown(with: event)
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0, dy: 4)
        if isActive {
            WorkspaceColor.selectedFill.setFill()
        } else if isHovered {
            WorkspaceColor.hoverFill.setFill()
        } else {
            return
        }
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
    }

    override func layout() {
        super.layout()
        iconView.frame = NSRect(x: 10, y: (bounds.height - 14) / 2, width: 14, height: 14)
        iconView.contentTintColor = isActive ? WorkspaceColor.accentText : WorkspaceColor.textSecondary
        titleLabel.textColor = isActive ? WorkspaceColor.textPrimary : WorkspaceColor.textSecondary
        titleLabel.frame = NSRect(x: 30, y: (bounds.height - 16) / 2, width: max(0, bounds.width - 30 - 26), height: 16)
        closeButton.frame = NSRect(x: bounds.width - 24, y: (bounds.height - 18) / 2, width: 18, height: 18)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
        needsDisplay = true
    }
}

/// A thin strip on the inspector's leading edge that resizes the column when dragged.
private final class InspectorResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        // The inspector sits at the window's right edge, so its width is the distance from the cursor.
        let point = superview.convert(event.locationInWindow, from: nil)
        onDrag?(superview.bounds.width - point.x)
    }

    override func mouseUp(with event: NSEvent) {
        onEnd?()
    }

    override var mouseDownCanMoveWindow: Bool { false }
}

final class WorkspaceInspectorView: NSView {
    private static let openTabsKey = "NoSyncWorkspaceInspectorTabs"
    private static let activeTabKey = "NoSyncWorkspaceInspectorActiveTab"
    static let stripHeight: CGFloat = 40

    private let tabStrip = NSScrollView()
    private let tabDocument = NSView()
    private let addButton = NSButton()
    private let expandButton = NSButton()
    private let stripBorder = NSView()
    private let leadingBorder = NSView()
    private let handle = InspectorResizeHandle()
    private let emptyLabel = InspectorMessageLabel(frame: .zero)
    private let changesPane = InspectorChangesPane(frame: .zero)
    private let filesPane = InspectorFilesPane(frame: .zero)
    private var terminalPanes = [String: InspectorTerminalPane]()
    private var tabButtons = [InspectorTabButton]()
    private(set) var openKinds: [InspectorTabKind]
    private(set) var activeKind: InspectorTabKind?
    private var sessionGuid: String?
    private var directory: String?
    private var isExpanded = false

    var onResize: ((CGFloat) -> Void)?
    var onResizeEnd: (() -> Void)?
    var onToggleExpand: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        openKinds = Self.loadOpenKinds()
        super.init(frame: frameRect)
        activeKind = Self.loadActiveKind(in: openKinds)
        wantsLayer = true
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Workspace.Inspector.A11y", defaultValue: "Inspector", comment: "Accessibility label of the inspector column"))

        tabStrip.documentView = tabDocument
        tabStrip.hasHorizontalScroller = false
        tabStrip.hasVerticalScroller = false
        tabStrip.drawsBackground = false
        tabStrip.horizontalScrollElasticity = .allowed
        tabStrip.verticalScrollElasticity = .none
        tabStrip.setAccessibilityRole(.tabGroup)
        tabStrip.setAccessibilityLabel(String(localized: "Workspace.Inspector.Tabs.A11y", defaultValue: "Inspector tabs", comment: "Accessibility label of the inspector's tab strip"))

        addButton.isBordered = false
        addButton.image = workspaceSymbolImage(.plus, pointSize: 13, weight: .medium)
        addButton.imagePosition = .imageOnly
        addButton.contentTintColor = WorkspaceColor.textSecondary
        addButton.toolTip = String(localized: "Workspace.Inspector.AddTab", defaultValue: "Add a tab", comment: "Tooltip and VoiceOver label of the inspector's + button")
        addButton.setAccessibilityLabel(addButton.toolTip)
        addButton.target = self
        addButton.action = #selector(showAddMenu(_:))
        updateExpandButton()
        expandButton.isBordered = false
        expandButton.imagePosition = .imageOnly
        expandButton.contentTintColor = WorkspaceColor.textSecondary
        expandButton.target = self
        expandButton.action = #selector(expandTapped)
        stripBorder.wantsLayer = true
        leadingBorder.wantsLayer = true
        handle.onDrag = { [weak self] width in self?.onResize?(width) }
        handle.onEnd = { [weak self] in self?.onResizeEnd?() }
        changesPane.isHidden = true
        filesPane.isHidden = true
        emptyLabel.isHidden = true
        emptyLabel.text = String(localized: "Workspace.Inspector.Empty",
                                 defaultValue: "No tabs open. Add one to see changes, a terminal or files.",
                                 comment: "Shown in the inspector when every tab has been closed")
        [changesPane, filesPane, emptyLabel, tabStrip, addButton, expandButton, stripBorder, leadingBorder, handle].forEach(addSubview)
        rebuildTabs()
        showActivePane()
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) has not been implemented")
    }

    // MARK: Persistence

    private static func loadOpenKinds() -> [InspectorTabKind] {
        let defaults = iTermUserDefaults.userDefaults()
        guard let stored = defaults.stringArray(forKey: openTabsKey) else {
            return InspectorTabKind.defaults
        }
        return stored.compactMap { InspectorTabKind(rawValue: $0) }.filter { $0.availability == .available }
    }

    private static func loadActiveKind(in kinds: [InspectorTabKind]) -> InspectorTabKind? {
        let raw = iTermUserDefaults.userDefaults().string(forKey: activeTabKey)
        if let kind = raw.flatMap({ InspectorTabKind(rawValue: $0) }), kinds.contains(kind) {
            return kind
        }
        return kinds.first
    }

    private func persist() {
        let defaults = iTermUserDefaults.userDefaults()
        defaults.set(openKinds.map { $0.rawValue }, forKey: Self.openTabsKey)
        defaults.set(activeKind?.rawValue, forKey: Self.activeTabKey)
    }

    // MARK: Session context

    /// Points every pane at the session that is active in the window.
    func setContext(sessionGuid: String?, directory: String?) {
        let sessionChanged = sessionGuid != self.sessionGuid
        self.sessionGuid = sessionGuid
        self.directory = directory
        changesPane.setDirectory(directory)
        filesPane.setDirectory(directory)
        if sessionChanged || directory != nil {
            showActivePane()
        }
    }

    /// Ends the shells of sessions that no longer exist.
    func pruneTerminals(keeping guids: Set<String>) {
        for (guid, pane) in terminalPanes where !guids.contains(guid) {
            pane.shutDown()
            pane.removeFromSuperview()
            terminalPanes[guid] = nil
        }
    }

    func shutDown() {
        terminalPanes.values.forEach { $0.shutDown() }
        terminalPanes = [:]
    }

    private func terminalPane(createIfNeeded: Bool) -> InspectorTerminalPane? {
        guard let sessionGuid else { return nil }
        if let existing = terminalPanes[sessionGuid] {
            return existing
        }
        guard createIfNeeded else { return nil }
        let pane = InspectorTerminalPane(frame: bounds)
        terminalPanes[sessionGuid] = pane
        addSubview(pane, positioned: .below, relativeTo: tabStrip)
        return pane
    }

    // MARK: Tabs

    func isOpen(_ kind: InspectorTabKind) -> Bool {
        return openKinds.contains(kind)
    }

    /// Opens the tab if needed and makes it active.
    func activate(_ kind: InspectorTabKind) {
        guard kind.availability == .available else { return }
        if !openKinds.contains(kind) {
            openKinds.append(kind)
            rebuildTabs()
        }
        activeKind = kind
        persist()
        updateTabSelection()
        showActivePane()
    }

    func focusActivePane() {
        guard let window else { return }
        switch activeKind {
        case .changes?: window.makeFirstResponder(changesPane.focusView)
        case .files?: window.makeFirstResponder(filesPane.focusView)
        case .terminal?:
            if let pane = terminalPane(createIfNeeded: true) { window.makeFirstResponder(pane.focusView) }
        default: break
        }
    }

    /// True when keyboard focus is inside the terminal pane.
    var terminalHasFocus: Bool {
        guard let responder = window?.firstResponder as? NSView, let pane = terminalPane(createIfNeeded: false) else { return false }
        return responder.isDescendant(of: pane)
    }

    var hasRunningTerminalJob: Bool {
        return terminalPanes.values.contains { $0.hasForegroundJob }
    }

    private func close(_ kind: InspectorTabKind) {
        if kind == .terminal, let pane = terminalPane(createIfNeeded: false), pane.hasForegroundJob, !confirmCloseTerminal() {
            return
        }
        guard let index = openKinds.firstIndex(of: kind) else { return }
        openKinds.remove(at: index)
        if kind == .terminal, let sessionGuid, let pane = terminalPanes[sessionGuid] {
            // Reopening starts a fresh shell.
            pane.shutDown()
            pane.removeFromSuperview()
            terminalPanes[sessionGuid] = nil
        }
        if activeKind == kind {
            activeKind = openKinds.isEmpty ? nil : openKinds[min(index, openKinds.count - 1)]
        }
        persist()
        rebuildTabs()
        showActivePane()
    }

    private func confirmCloseTerminal() -> Bool {
        let warning = iTermWarning()
        warning.heading = String(localized: "Workspace.Inspector.Terminal.CloseTitle", defaultValue: "Close this terminal?", comment: "Alert title when closing the inspector terminal while a command is running")
        warning.title = String(localized: "Workspace.Inspector.Terminal.CloseBody", defaultValue: "A command is still running in this terminal. Closing it ends the shell and stops the command.", comment: "Alert body when closing the inspector terminal while a command is running")
        warning.actionLabels = [String(localized: "Workspace.Inspector.Terminal.CloseButton", defaultValue: "Close terminal", comment: "Destructive button that closes the inspector terminal"),
                                String(localized: "Workspace.Inspector.Terminal.KeepButton", defaultValue: "Keep open", comment: "Cancel button of the alert that asks before closing the inspector terminal")]
        warning.warningType = .kiTermWarningTypePersistent
        warning.window = window
        return warning.runModal() == .kiTermWarningSelection0
    }

    private func move(_ kind: InspectorTabKind, by delta: Int) {
        guard let index = openKinds.firstIndex(of: kind) else { return }
        let target = index + delta
        guard openKinds.indices.contains(target) else { return }
        let next = openKinds[target]
        activate(next)
        if let button = tabButtons.first(where: { $0.kind == next }) {
            window?.makeFirstResponder(button)
        }
    }

    private func rebuildTabs() {
        tabButtons.forEach { $0.removeFromSuperview() }
        tabButtons = openKinds.map { kind in
            let button = InspectorTabButton(kind: kind)
            button.onSelect = { [weak self] in self?.activate($0) }
            button.onClose = { [weak self] in self?.close($0) }
            button.onMove = { [weak self] in self?.move($0, by: $1) }
            tabDocument.addSubview(button)
            return button
        }
        updateTabSelection()
        needsLayout = true
    }

    private func updateTabSelection() {
        for button in tabButtons {
            button.isActive = button.kind == activeKind
            button.needsLayout = true
        }
        if let active = tabButtons.first(where: { $0.isActive }) {
            tabDocument.scrollToVisible(active.frame)
        }
    }

    private func showActivePane() {
        emptyLabel.isHidden = activeKind != nil
        changesPane.isHidden = activeKind != .changes
        filesPane.isHidden = activeKind != .files
        changesPane.setVisibleInInspector(activeKind == .changes && !isHiddenOrHasHiddenAncestor)
        filesPane.setVisibleInInspector(activeKind == .files && !isHiddenOrHasHiddenAncestor)
        for (guid, pane) in terminalPanes {
            pane.isHidden = !(activeKind == .terminal && guid == sessionGuid)
        }
        if activeKind == .terminal, let pane = terminalPane(createIfNeeded: true), let directory {
            pane.isHidden = false
            pane.start(in: directory)
        }
        needsLayout = true
    }

    override func viewDidHide() {
        super.viewDidHide()
        showActivePane()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        showActivePane()
    }

    // MARK: Add menu

    @objc private func showAddMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let tagSoon = String(localized: "Workspace.Inspector.Tag.Soon", defaultValue: "Soon", comment: "Tag on an inspector menu item that ships soon")
        let tagLater = String(localized: "Workspace.Inspector.Tag.Later", defaultValue: "Later", comment: "Tag on an inspector menu item that ships in a later version")
        let order: [InspectorTabKind] = [.changes, .pullRequest, .terminal, .browser, .files, .sideChat]
        for kind in order {
            let title = InspectorTabButton.title(for: kind)
            let item = NSMenuItem(title: title, action: #selector(addMenuChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            item.image = workspaceSymbolImage(InspectorTabButton.symbol(for: kind), pointSize: 13)
            switch kind.availability {
            case .available:
                if isOpen(kind) {
                    item.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.secondaryLabelColor])
                }
            case .soon:
                item.isEnabled = false
                item.title = "\(title)  \(tagSoon)"
            case .later:
                item.isEnabled = false
                item.title = "\(title)  \(tagLater)"
            }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func addMenuChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = InspectorTabKind(rawValue: raw) else { return }
        activate(kind)
        focusActivePane()
    }

    // MARK: Expand

    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        updateExpandButton()
    }

    private func updateExpandButton() {
        expandButton.image = workspaceSymbolImage(isExpanded ? .arrowDownRightAndArrowUpLeft : .arrowUpLeftAndArrowDownRight, pointSize: 12, weight: .medium)
        expandButton.toolTip = isExpanded
            ? String(localized: "Workspace.Inspector.Restore", defaultValue: "Restore inspector width", comment: "Tooltip of the inspector's expand control once the inspector is expanded")
            : String(localized: "Workspace.Inspector.Expand", defaultValue: "Expand inspector", comment: "Tooltip of the inspector's expand control")
        expandButton.setAccessibilityLabel(expandButton.toolTip)
    }

    @objc private func expandTapped() {
        onToggleExpand?()
    }

    // MARK: Layout

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = WorkspaceColor.windowBackground.cgColor
            stripBorder.layer?.backgroundColor = WorkspaceColor.separator.cgColor
            leadingBorder.layer?.backgroundColor = WorkspaceColor.separator.cgColor
        }
        let strip = Self.stripHeight
        let controlsWidth: CGFloat = 64
        tabStrip.frame = NSRect(x: 1, y: 0, width: max(0, bounds.width - controlsWidth - 1), height: strip)
        addButton.frame = NSRect(x: bounds.width - controlsWidth + 4, y: 6, width: 28, height: 28)
        expandButton.frame = NSRect(x: bounds.width - 32, y: 6, width: 28, height: 28)
        stripBorder.frame = NSRect(x: 0, y: strip - 1, width: bounds.width, height: 1)
        leadingBorder.frame = NSRect(x: 0, y: 0, width: 1, height: bounds.height)
        handle.frame = NSRect(x: 0, y: 0, width: 6, height: bounds.height)

        var x: CGFloat = 4
        for button in tabButtons {
            let width = button.idealWidth
            button.frame = NSRect(x: x, y: 0, width: width, height: strip - 1)
            x += width + 2
        }
        tabDocument.frame = NSRect(x: 0, y: 0, width: max(x + 4, tabStrip.bounds.width), height: strip - 1)

        let body = NSRect(x: 1, y: strip, width: max(0, bounds.width - 1), height: max(0, bounds.height - strip))
        changesPane.frame = body
        filesPane.frame = body
        emptyLabel.frame = body
        terminalPanes.values.forEach { $0.frame = body }
    }
}
