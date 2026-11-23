//
//  InspectorChangesPane.swift
//  iTerm2SharedARC
//
//  The inspector's Changes tab: files changed since HEAD plus untracked files, each expandable to
//  an inline unified diff. Diffs load lazily when a file opens.
//

import AppKit

/// A centered, wrapping line used for empty and error states inside inspector panes.
final class InspectorMessageLabel: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")

    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 13)
        label.textColor = WorkspaceColor.textSecondary
        label.alignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let width = max(0, min(bounds.width - 40, 320))
        label.preferredMaxLayoutWidth = width
        let height = label.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height
        label.frame = NSRect(x: (bounds.width - width) / 2, y: max(24, bounds.height * 0.3 - height / 2), width: width, height: height)
    }
}

private final class ChangesRowView: NSTableCellView {
    private let badge = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let marker = NSTextField(labelWithString: "")
    private let chevron = NSImageView()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        [badge, pathLabel, countLabel, marker, chevron].forEach(addSubview)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.cell?.truncatesLastVisibleLine = true
        countLabel.alignment = .right
        chevron.contentTintColor = WorkspaceColor.textSecondary
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) has not been implemented")
    }

    func configureFile(_ change: GitFileChange, expanded: Bool) {
        layer?.backgroundColor = nil
        marker.isHidden = true
        chevron.isHidden = false
        chevron.image = workspaceSymbolImage(expanded ? .chevronDown : .chevronRight, pointSize: 10, weight: .semibold)
        badge.isHidden = false
        badge.stringValue = String(change.status)
        badge.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        badge.alignment = .center
        badge.textColor = Self.color(for: change.status)
        pathLabel.stringValue = change.path
        pathLabel.font = .systemFont(ofSize: 12.5)
        pathLabel.textColor = WorkspaceColor.textPrimary
        pathLabel.toolTip = change.oldPath.map { "\($0) → \(change.path)" } ?? change.path
        countLabel.isHidden = false
        countLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        countLabel.attributedStringValue = Self.counts(for: change)
        setAccessibilityLabel(Self.accessibilityDescription(for: change))
    }

    func configureDiff(_ line: DiffLine) {
        badge.isHidden = true
        chevron.isHidden = true
        countLabel.isHidden = true
        pathLabel.toolTip = nil
        pathLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        pathLabel.lineBreakMode = .byClipping
        marker.isHidden = false
        marker.font = .monospacedSystemFont(ofSize: 11.5, weight: .semibold)
        wantsLayer = true
        switch line.kind {
        case .added:
            marker.stringValue = "+"
            marker.textColor = WorkspaceColor.successText
            pathLabel.textColor = WorkspaceColor.textPrimary
            layer?.backgroundColor = WorkspaceColor.success.withAlphaComponent(0.14).cgColor
        case .removed:
            marker.stringValue = "−"
            marker.textColor = WorkspaceColor.danger
            pathLabel.textColor = WorkspaceColor.textPrimary
            layer?.backgroundColor = WorkspaceColor.danger.withAlphaComponent(0.14).cgColor
        case .hunk:
            marker.stringValue = ""
            pathLabel.textColor = WorkspaceColor.accentText
            layer?.backgroundColor = WorkspaceColor.accentSoft.cgColor
        case .context, .note:
            marker.stringValue = ""
            pathLabel.textColor = WorkspaceColor.textSecondary
            layer?.backgroundColor = nil
        }
        pathLabel.stringValue = line.text
        let spoken: String
        switch line.kind {
        case .added: spoken = String(localized: "Workspace.Inspector.Changes.A11y.Added", defaultValue: "Added: \(line.text)", comment: "VoiceOver label of an added diff line. The placeholder is the line.")
        case .removed: spoken = String(localized: "Workspace.Inspector.Changes.A11y.Removed", defaultValue: "Removed: \(line.text)", comment: "VoiceOver label of a removed diff line. The placeholder is the line.")
        default: spoken = line.text
        }
        setAccessibilityLabel(spoken)
    }

    func configureNote(_ text: String, action: Bool) {
        badge.isHidden = true
        chevron.isHidden = true
        countLabel.isHidden = true
        marker.isHidden = true
        layer?.backgroundColor = nil
        pathLabel.stringValue = text
        pathLabel.font = .systemFont(ofSize: 12)
        pathLabel.lineBreakMode = .byTruncatingTail
        pathLabel.textColor = action ? WorkspaceColor.accentText : WorkspaceColor.textSecondary
        setAccessibilityLabel(text)
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let lineHeight: CGFloat = 16
        let y = (h - lineHeight) / 2
        if !chevron.isHidden {
            chevron.frame = NSRect(x: 10, y: (h - 12) / 2, width: 12, height: 12)
            badge.frame = NSRect(x: 26, y: y, width: 14, height: lineHeight)
            let countWidth = min(110, max(0, countLabel.attributedStringValue.size().width + 4))
            countLabel.frame = NSRect(x: bounds.width - countWidth - 12, y: y, width: countWidth, height: lineHeight)
            pathLabel.frame = NSRect(x: 46, y: y, width: max(0, countLabel.frame.minX - 52), height: lineHeight)
        } else if !marker.isHidden {
            marker.frame = NSRect(x: 12, y: y, width: 12, height: lineHeight)
            pathLabel.frame = NSRect(x: 28, y: y, width: max(0, bounds.width - 36), height: lineHeight)
        } else {
            pathLabel.frame = NSRect(x: 28, y: y, width: max(0, bounds.width - 40), height: lineHeight)
        }
    }

    private static func color(for status: Character) -> NSColor {
        switch status {
        case "A", "?": return WorkspaceColor.successText
        case "D": return WorkspaceColor.danger
        case "R": return WorkspaceColor.accentText
        default: return WorkspaceColor.warningText
        }
    }

    private static func counts(for change: GitFileChange) -> NSAttributedString {
        let result = NSMutableAttributedString()
        guard let added = change.added, let removed = change.removed else {
            return result
        }
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        result.append(NSAttributedString(string: "+\(added)", attributes: [.foregroundColor: WorkspaceColor.successText, .font: font]))
        result.append(NSAttributedString(string: " −\(removed)", attributes: [.foregroundColor: WorkspaceColor.danger, .font: font]))
        return result
    }

    private static func accessibilityDescription(for change: GitFileChange) -> String {
        let status: String
        switch change.status {
        case "A": status = String(localized: "Workspace.Inspector.Changes.Status.Added", defaultValue: "Added", comment: "VoiceOver word for a file added in the working tree")
        case "D": status = String(localized: "Workspace.Inspector.Changes.Status.Deleted", defaultValue: "Deleted", comment: "VoiceOver word for a file deleted in the working tree")
        case "R": status = String(localized: "Workspace.Inspector.Changes.Status.Renamed", defaultValue: "Renamed", comment: "VoiceOver word for a renamed file")
        case "?": status = String(localized: "Workspace.Inspector.Changes.Status.Untracked", defaultValue: "Untracked", comment: "VoiceOver word for a file git doesn't track yet")
        default: status = String(localized: "Workspace.Inspector.Changes.Status.Modified", defaultValue: "Modified", comment: "VoiceOver word for a modified file")
        }
        return "\(status), \(change.path)"
    }
}

private final class ChangesTableView: NSTableView {
    var onActivate: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 49 {
            onActivate?()
            return
        }
        super.keyDown(with: event)
    }
}

final class InspectorChangesPane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private enum Item {
        case file(GitFileChange, expanded: Bool)
        case diff(DiffLine)
        case note(String)
        case more(path: String, remaining: Int)
    }

    private enum DiffState {
        case loading
        case loaded(ParsedDiff, shown: Int)
    }

    private static let pageSize = 500

    private let summaryLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton()
    private let divider = NSView()
    private let scrollView = NSScrollView()
    private let table = ChangesTableView()
    private let message = InspectorMessageLabel(frame: .zero)
    private var items = [Item]()
    private var changes = [GitFileChange]()
    private var expansion = [String: DiffState]()
    private var directory: String?
    private var root: String?
    private var watcher: DirectoryWatcher?
    private var generation = 0
    private var isVisibleInInspector = false
    private var stale = true

    override var isFlipped: Bool { true }
    var focusView: NSView { table }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Workspace.Inspector.Tab.Changes", defaultValue: "Changes", comment: "Inspector tab label"))
        summaryLabel.font = .systemFont(ofSize: 12, weight: .medium)
        summaryLabel.textColor = WorkspaceColor.textSecondary
        refreshButton.isBordered = false
        refreshButton.image = workspaceSymbolImage(.arrowClockwise, pointSize: 12)
        refreshButton.imagePosition = .imageOnly
        refreshButton.contentTintColor = WorkspaceColor.textSecondary
        refreshButton.toolTip = String(localized: "Workspace.Inspector.Changes.Refresh", defaultValue: "Refresh changes", comment: "Tooltip of the button that reloads the list of changed files")
        refreshButton.setAccessibilityLabel(refreshButton.toolTip)
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        divider.wantsLayer = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("change"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.onActivate = { [weak self] in self?.activateSelectedRow() }
        table.setAccessibilityLabel(String(localized: "Workspace.Inspector.Changes.List.A11y", defaultValue: "Changed files", comment: "Accessibility label of the changed files list"))
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        [summaryLabel, refreshButton, divider, scrollView, message].forEach(addSubview)
        message.isHidden = true
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) has not been implemented")
    }

    deinit {
        watcher?.stop()
    }

    // MARK: Data

    func setDirectory(_ newDirectory: String?) {
        guard newDirectory != directory else { return }
        directory = newDirectory
        root = nil
        changes = []
        expansion = [:]
        watcher?.stop()
        watcher = nil
        generation += 1
        stale = true
        showMessage(newDirectory == nil ? noRepoText : nil)
        rebuild()
        if isVisibleInInspector {
            resolveRootAndRefresh()
        }
    }

    /// Called as the pane becomes visible or hidden. Watching only runs while it is visible.
    func setVisibleInInspector(_ visible: Bool) {
        guard visible != isVisibleInInspector else { return }
        isVisibleInInspector = visible
        if visible {
            if root == nil, directory != nil {
                resolveRootAndRefresh()
            } else {
                startWatching()
                refresh()
            }
        } else {
            watcher?.stop()
            watcher = nil
        }
    }

    private var noRepoText: String {
        return String(localized: "Workspace.Inspector.Changes.NoRepo",
                      defaultValue: "This folder isn’t in a git repo, so there are no changes to show.",
                      comment: "Shown in the inspector's Changes tab when the session's folder has no git repository")
    }

    private func resolveRootAndRefresh() {
        guard let directory else { return }
        let token = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let resolved = InspectorGit.repoRoot(for: directory)
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.root = resolved
                if resolved == nil {
                    self.showMessage(self.noRepoText)
                } else {
                    self.startWatching()
                    self.refresh()
                }
            }
        }
    }

    private func startWatching() {
        guard watcher == nil, let root else { return }
        watcher = DirectoryWatcher(path: root) { [weak self] in
            self?.refresh()
        }
    }

    @objc private func refreshTapped() {
        refresh()
    }

    func refresh() {
        guard let root else { return }
        let token = generation
        let reopen = expansion.keys
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = InspectorGit.changes(root: root)
            var diffs = [String: ParsedDiff]()
            if let result {
                for change in result where reopen.contains(change.path) {
                    diffs[change.path] = InspectorGit.diff(root: root, change: change)
                }
            }
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                guard let result else {
                    self.changes = []
                    self.expansion = [:]
                    self.showMessage(String(localized: "Workspace.Inspector.Changes.Error",
                                            defaultValue: "Couldn’t read this repo’s changes.",
                                            comment: "Shown in the inspector's Changes tab when git fails"))
                    self.rebuild()
                    return
                }
                self.stale = false
                self.changes = result
                let known = Set(result.map { $0.path })
                self.expansion = self.expansion.filter { known.contains($0.key) }
                for (path, diff) in diffs where self.expansion[path] != nil {
                    var shown = Self.pageSize
                    if case .loaded(_, let previous)? = self.expansion[path] { shown = max(previous, Self.pageSize) }
                    self.expansion[path] = .loaded(diff, shown: shown)
                }
                self.showMessage(result.isEmpty ? String(localized: "Workspace.Inspector.Changes.Empty",
                                                         defaultValue: "No uncommitted changes.",
                                                         comment: "Shown in the inspector's Changes tab when nothing has changed") : nil)
                self.rebuild()
            }
        }
    }

    private func showMessage(_ text: String?) {
        message.isHidden = text == nil
        scrollView.isHidden = text != nil
        if let text { message.text = text }
        let count = changes.count
        summaryLabel.stringValue = text == nil ? Self.summary(count: count) : ""
        needsLayout = true
    }

    private func rebuild() {
        var next = [Item]()
        for change in changes {
            let state = expansion[change.path]
            next.append(.file(change, expanded: state != nil))
            switch state {
            case nil:
                break
            case .loading?:
                next.append(.note(String(localized: "Workspace.Inspector.Changes.Loading", defaultValue: "Loading…", comment: "Row shown while a file's diff loads")))
            case .loaded(let diff, let shown)?:
                if diff.isBinary || change.isBinary {
                    next.append(.note(String(localized: "Workspace.Inspector.Changes.Binary", defaultValue: "Binary file changed", comment: "Row note for a binary file in the changes list")))
                } else if diff.lines.isEmpty {
                    next.append(.note(String(localized: "Workspace.Inspector.Changes.NoDiff", defaultValue: "No line changes", comment: "Row note when a changed file has no line-level diff, such as an empty new file")))
                } else {
                    next.append(contentsOf: diff.lines.prefix(shown).map { Item.diff($0) })
                    if diff.lines.count > shown {
                        next.append(.more(path: change.path, remaining: diff.lines.count - shown))
                    }
                }
            }
        }
        items = next
        table.reloadData()
        if !scrollView.isHidden {
            summaryLabel.stringValue = Self.summary(count: changes.count)
        }
    }

    private static func summary(count: Int) -> String {
        if count == 1 {
            return String(localized: "Workspace.Inspector.Changes.Summary.One", defaultValue: "1 file changed", comment: "Summary line above the list of changed files when exactly one file changed")
        }
        return String(localized: "Workspace.Inspector.Changes.Summary.Other", defaultValue: "\(count) files changed", comment: "Summary line above the list of changed files. The placeholder is the number of files, which is not 1.")
    }

    // MARK: Actions

    @objc private func rowClicked() {
        let row = table.clickedRow
        activate(row: row)
    }

    func activateSelectedRow() {
        activate(row: table.selectedRow)
    }

    private func activate(row: Int) {
        guard row >= 0, row < items.count else { return }
        switch items[row] {
        case .file(let change, let expanded):
            if expanded {
                expansion[change.path] = nil
                rebuild()
            } else {
                load(change)
            }
        case .more(let path, _):
            if case .loaded(let diff, let shown)? = expansion[path] {
                expansion[path] = .loaded(diff, shown: shown + Self.pageSize)
                rebuild()
            }
        default:
            break
        }
    }

    private func load(_ change: GitFileChange) {
        guard let root else { return }
        expansion[change.path] = .loading
        rebuild()
        let token = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let diff = InspectorGit.diff(root: root, change: change)
            DispatchQueue.main.async {
                guard let self, token == self.generation, self.expansion[change.path] != nil else { return }
                self.expansion[change.path] = .loaded(diff, shown: Self.pageSize)
                self.rebuild()
            }
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        return items.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch items[row] {
        case .file: return 28
        default: return 20
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch items[row] {
        case .file, .more: return true
        default: return false
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ChangesRow")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? ChangesRowView) ?? {
            let view = ChangesRowView(frame: .zero)
            view.identifier = identifier
            return view
        }()
        switch items[row] {
        case .file(let change, let expanded):
            cell.configureFile(change, expanded: expanded)
        case .diff(let line):
            cell.configureDiff(line)
        case .note(let text):
            cell.configureNote(text, action: false)
        case .more(_, let remaining):
            let title = String(localized: "Workspace.Inspector.Changes.ShowMore", defaultValue: "Show more", comment: "Button that reveals more lines of a long diff")
            cell.configureNote("\(title) (\(remaining))", action: true)
        }
        return cell
    }

    // MARK: Layout

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
        table.reloadData()
    }

    override func layout() {
        super.layout()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            divider.layer?.backgroundColor = WorkspaceColor.separator.cgColor
        }
        let headerHeight: CGFloat = 32
        summaryLabel.frame = NSRect(x: 14, y: 8, width: max(0, bounds.width - 56), height: 16)
        refreshButton.frame = NSRect(x: bounds.width - 38, y: 2, width: 28, height: 28)
        divider.frame = NSRect(x: 0, y: headerHeight, width: bounds.width, height: 1)
        let body = NSRect(x: 0, y: headerHeight + 1, width: bounds.width, height: max(0, bounds.height - headerHeight - 1))
        scrollView.frame = body
        message.frame = body
        table.tableColumns.first?.width = body.width
    }
}
