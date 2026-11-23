//
//  WorkspaceListPage.swift
//  iTerm2SharedARC
//
//  The shared shell of the full-window Pull requests, Issues and Automations views: a segmented
//  control, filter pop-ups, a list of rows with hover actions, a footer, and inline states for
//  loading, empty results and setup problems.
//

import AppKit

func workspaceSymbolImage(_ symbol: SFSymbol, pointSize: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight, scale: .medium)
    return NSImage(systemSymbolName: symbol.rawValue, accessibilityDescription: nil)?
        .withSymbolConfiguration(config)
}

struct WorkspaceListAction: Equatable {
    var identifier: String
    var title: String
    var enabled = true
    var tooltip: String?
}

struct WorkspaceListRow {
    var id: String
    var symbol: SFSymbol
    var tint: NSColor
    var title: String
    var subtitle: String
    var chips: [String] = []
    var trailing: String?
    var trailingTint: NSColor?
    var actions: [WorkspaceListAction] = []
    var menuActions: [WorkspaceListAction] = []
    var accessibilityLabel: String?
}

struct WorkspaceListFilter {
    var title: String
    var items: [String]
    var selected: Int
}

// MARK: - Row view

private final class WorkspaceListRowView: NSTableCellView {
    private let icon = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let trailingField = NSTextField(labelWithString: "")
    private let chipStack = NSStackView()
    private var actionButtons = [NSButton]()
    private var actions = [WorkspaceListAction]()
    private var tracking: NSTrackingArea?
    var onAction: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        titleField.textColor = WorkspaceColor.textPrimary
        titleField.lineBreakMode = .byTruncatingTail
        subtitleField.font = .systemFont(ofSize: 12)
        subtitleField.textColor = WorkspaceColor.textSecondary
        subtitleField.lineBreakMode = .byTruncatingTail
        trailingField.font = .systemFont(ofSize: 12)
        trailingField.textColor = WorkspaceColor.textSecondary
        trailingField.alignment = .right
        trailingField.setContentCompressionResistancePriority(.required, for: .horizontal)
        chipStack.orientation = .horizontal
        chipStack.spacing = 4
        chipStack.setContentHuggingPriority(.required, for: .horizontal)
        chipStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        let textStack = NSStackView(views: [titleField, subtitleField])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        let row = NSStackView(views: [icon, textStack, chipStack, trailingField])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18)
        ])
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        it_fatalError("Not supported")
    }

    func configure(with row: WorkspaceListRow) {
        icon.image = workspaceSymbolImage(row.symbol, pointSize: 15)
        icon.contentTintColor = row.tint
        titleField.stringValue = row.title
        subtitleField.stringValue = row.subtitle
        trailingField.stringValue = row.trailing ?? ""
        trailingField.textColor = row.trailingTint ?? WorkspaceColor.textSecondary
        for view in chipStack.arrangedSubviews {
            chipStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for chip in row.chips {
            chipStack.addArrangedSubview(Self.makeChip(chip))
        }
        for button in actionButtons {
            button.removeFromSuperview()
        }
        actionButtons = []
        actions = row.actions
        for action in row.actions {
            let button = NSButton(title: action.title, target: self, action: #selector(actionClicked(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.isEnabled = action.enabled
            button.toolTip = action.tooltip
            button.identifier = NSUserInterfaceItemIdentifier(action.identifier)
            button.isHidden = true
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            actionButtons.append(button)
        }
        var trailingAnchorView = trailingAnchor
        for button in actionButtons.reversed() {
            button.trailingAnchor.constraint(equalTo: trailingAnchorView, constant: trailingAnchorView == trailingAnchor ? -16 : -6).isActive = true
            button.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
            trailingAnchorView = button.leadingAnchor
        }
        setAccessibilityLabel(row.accessibilityLabel ?? "\(row.title), \(row.subtitle)")
        setAccessibilityElement(true)
    }

    private static func makeChip(_ text: String) -> NSView {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = WorkspaceColor.textSecondaryStrong
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.backgroundColor = WorkspaceColor.chipFill.cgColor
        field.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 7),
            field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -7),
            field.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
            field.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1)
        ])
        return box
    }

    @objc private func actionClicked(_ sender: NSButton) {
        if let identifier = sender.identifier?.rawValue {
            onAction?(identifier)
        }
    }

    private func setActionsVisible(_ visible: Bool) {
        for button in actionButtons {
            button.isHidden = !visible
        }
        trailingField.isHidden = visible && !actionButtons.isEmpty
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        setActionsVisible(true)
    }

    override func mouseExited(with event: NSEvent) {
        setActionsVisible(false)
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            setActionsVisible(backgroundStyle == .emphasized)
        }
    }
}

// MARK: - Inline message

final class WorkspaceMessageView: NSView {
    private let heading = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private let commandField = NSTextField(labelWithString: "")
    private let copyButton: NSButton
    private let retryButton: NSButton
    private let spinner = NSProgressIndicator()
    var onCopy: (() -> Void)?
    var onRetry: (() -> Void)?

    override init(frame: NSRect) {
        copyButton = NSButton(title: String(localized: "Workspace.Setup.Copy",
                                            defaultValue: "Copy",
                                            comment: "Button that copies a command to the clipboard"),
                              target: nil, action: nil)
        retryButton = NSButton(title: String(localized: "Workspace.Setup.CheckAgain",
                                             defaultValue: "Check again",
                                             comment: "Button that re-checks whether the GitHub command line tool is ready"),
                               target: nil, action: nil)
        super.init(frame: frame)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.textColor = WorkspaceColor.textPrimary
        heading.alignment = .center
        body.font = .systemFont(ofSize: 13)
        body.textColor = WorkspaceColor.textSecondary
        body.alignment = .center
        body.preferredMaxLayoutWidth = 360
        commandField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        commandField.textColor = WorkspaceColor.textPrimary
        commandField.isSelectable = true
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        copyButton.bezelStyle = .rounded
        retryButton.target = self
        retryButton.action = #selector(retryTapped)
        retryButton.bezelStyle = .rounded
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false

        let commandRow = NSStackView(views: [commandField, copyButton])
        commandRow.orientation = .horizontal
        commandRow.spacing = 8
        let stack = NSStackView(views: [spinner, heading, body, commandRow, retryButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 400)
        ])
    }

    required init?(coder: NSCoder) {
        it_fatalError("Not supported")
    }

    func showLoading(_ label: String) {
        spinner.startAnimation(nil)
        heading.stringValue = ""
        heading.isHidden = true
        body.stringValue = label
        commandField.superview?.isHidden = true
        retryButton.isHidden = true
        setAccessibilityLabel(label)
    }

    func show(heading headingText: String,
              body bodyText: String,
              command: String? = nil,
              retryTitle: String? = nil) {
        spinner.stopAnimation(nil)
        heading.stringValue = headingText
        heading.isHidden = headingText.isEmpty
        body.stringValue = bodyText
        commandField.stringValue = command ?? ""
        commandField.superview?.isHidden = command == nil
        retryButton.title = retryTitle ?? retryButton.title
        retryButton.isHidden = retryTitle == nil
        setAccessibilityLabel("\(headingText). \(bodyText)")
    }

    @objc private func copyTapped() {
        onCopy?()
    }

    @objc private func retryTapped() {
        onRetry?()
    }
}

// MARK: - Page

final class WorkspaceListPage: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let segmented = NSSegmentedControl()
    private let filterStack = NSStackView()
    private let scrollView = NSScrollView()
    private let table = NSTableView()
    private let message = WorkspaceMessageView(frame: .zero)
    private let staleLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton()
    private let separatorTop = NSBox()
    private let separatorBottom = NSBox()
    private var rows = [WorkspaceListRow]()
    private var filterPopups = [NSPopUpButton]()

    var onSegmentChange: ((Int) -> Void)?
    var onFilterChange: ((Int, Int) -> Void)?
    var onRefresh: (() -> Void)?
    var onSelectRow: ((String) -> Void)?
    var onAction: ((String, String) -> Void)?

    var segmentedHidden: Bool {
        get { segmented.isHidden }
        set { segmented.isHidden = newValue }
    }

    var messageView: WorkspaceMessageView { message }
    var focusView: NSView { table }

    override init(frame: NSRect) {
        super.init(frame: frame)
        segmented.segmentStyle = .rounded
        segmented.trackingMode = .selectOne
        segmented.target = self
        segmented.action = #selector(segmentChanged)
        filterStack.orientation = .horizontal
        filterStack.spacing = 8

        let controls = NSStackView(views: [segmented, NSView(), filterStack])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 56
        table.intercellSpacing = .zero
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.setAccessibilityLabel("Results")
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        message.translatesAutoresizingMaskIntoConstraints = false
        message.isHidden = true

        staleLabel.font = .systemFont(ofSize: 12)
        staleLabel.textColor = WorkspaceColor.warningText
        staleLabel.isHidden = true
        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = WorkspaceColor.textSecondary
        refreshButton.image = workspaceSymbolImage(.arrowTriangle2Circlepath, pointSize: 12)
        refreshButton.isBordered = false
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        refreshButton.toolTip = String(localized: "Workspace.List.Footer.RefreshTooltip",
                                       defaultValue: "Refresh",
                                       comment: "Tooltip of the button that reloads a list from GitHub")
        refreshButton.setAccessibilityLabel(refreshButton.toolTip)
        let footer = NSStackView(views: [footerLabel, staleLabel, NSView(), refreshButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false
        separatorTop.boxType = .separator
        separatorBottom.boxType = .separator
        separatorTop.translatesAutoresizingMaskIntoConstraints = false
        separatorBottom.translatesAutoresizingMaskIntoConstraints = false

        for view in [controls, separatorTop, scrollView, message, separatorBottom, footer] {
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            separatorTop.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 12),
            separatorTop.leadingAnchor.constraint(equalTo: leadingAnchor),
            separatorTop.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: separatorTop.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: separatorBottom.topAnchor),
            message.topAnchor.constraint(equalTo: scrollView.topAnchor),
            message.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            message.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            separatorBottom.leadingAnchor.constraint(equalTo: leadingAnchor),
            separatorBottom.trailingAnchor.constraint(equalTo: trailingAnchor),
            separatorBottom.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) {
        it_fatalError("Not supported")
    }

    // MARK: Configuration

    func setSegments(_ titles: [String], selected: Int) {
        segmented.segmentCount = titles.count
        for (index, title) in titles.enumerated() {
            segmented.setLabel(title, forSegment: index)
        }
        segmented.selectedSegment = selected
    }

    func setFilters(_ filters: [WorkspaceListFilter]) {
        for view in filterStack.arrangedSubviews {
            filterStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        filterPopups = []
        for (index, filter) in filters.enumerated() {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.controlSize = .small
            popup.addItems(withTitles: filter.items)
            popup.selectItem(at: filter.selected)
            popup.tag = index
            popup.target = self
            popup.action = #selector(filterChanged(_:))
            popup.setAccessibilityLabel(filter.title)
            filterStack.addArrangedSubview(popup)
            filterPopups.append(popup)
        }
    }

    func show(rows newRows: [WorkspaceListRow], footer: String, staleNotice: String?) {
        rows = newRows
        let selected = table.selectedRow
        table.reloadData()
        if selected >= 0, selected < rows.count {
            table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        }
        scrollView.isHidden = false
        message.isHidden = true
        footerLabel.stringValue = footer
        staleLabel.stringValue = staleNotice ?? ""
        staleLabel.isHidden = staleNotice == nil
        if let staleNotice {
            NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [.announcement: staleNotice])
        }
    }

    func showMessage(footer: String = "") {
        scrollView.isHidden = true
        message.isHidden = false
        footerLabel.stringValue = footer
    }

    func showStale(_ notice: String?) {
        staleLabel.stringValue = notice ?? ""
        staleLabel.isHidden = notice == nil
    }

    // MARK: Actions

    @objc private func segmentChanged() {
        onSegmentChange?(segmented.selectedSegment)
    }

    @objc private func filterChanged(_ sender: NSPopUpButton) {
        onFilterChange?(sender.tag, sender.indexOfSelectedItem)
    }

    @objc private func refreshTapped() {
        onRefresh?()
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard row >= 0, row < rows.count else { return }
        onSelectRow?(rows[row].id)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, table.selectedRow >= 0, table.selectedRow < rows.count {
            onSelectRow?(rows[table.selectedRow].id)
            return
        }
        super.keyDown(with: event)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        return rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("WorkspaceListRow")
        let view = (tableView.makeView(withIdentifier: identifier, owner: nil) as? WorkspaceListRowView)
            ?? WorkspaceListRowView(frame: .zero)
        view.identifier = identifier
        let model = rows[row]
        view.configure(with: model)
        view.onAction = { [weak self] action in
            self?.onAction?(model.id, action)
        }
        return view
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        return nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = table.convert(event.locationInWindow, from: nil)
        let row = table.row(at: point)
        guard row >= 0, row < rows.count else { return nil }
        let model = rows[row]
        let items = model.menuActions + model.actions
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        for action in items {
            let item = NSMenuItem(title: action.title, action: #selector(menuActionChosen(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = action.enabled
            item.representedObject = [model.id, action.identifier]
            menu.addItem(item)
        }
        return menu
    }

    @objc private func menuActionChosen(_ sender: NSMenuItem) {
        if let pair = sender.representedObject as? [String], pair.count == 2 {
            onAction?(pair[0], pair[1])
        }
    }
}
