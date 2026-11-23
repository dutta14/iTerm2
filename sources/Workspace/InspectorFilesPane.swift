//
//  InspectorFilesPane.swift
//  iTerm2SharedARC
//
//  The inspector's Files tab: a lazy tree of the repo's tracked and untracked files.
//

import AppKit

final class InspectorFileNode {
    let name: String
    let relativePath: String
    var isDirectory: Bool
    var children = [InspectorFileNode]()

    init(name: String, relativePath: String, isDirectory: Bool) {
        self.name = name
        self.relativePath = relativePath
        self.isDirectory = isDirectory
    }

    /// Builds a tree from slash-separated paths. Directories sort before files.
    static func tree(from paths: [String]) -> [InspectorFileNode] {
        let top = InspectorFileNode(name: "", relativePath: "", isDirectory: true)
        var lookup = [String: InspectorFileNode]()
        for path in paths {
            var parent = top
            var built = ""
            let parts = path.split(separator: "/").map(String.init)
            for (index, part) in parts.enumerated() {
                built = built.isEmpty ? part : built + "/" + part
                let isLast = index == parts.count - 1
                if let existing = lookup[built] {
                    parent = existing
                    continue
                }
                let node = InspectorFileNode(name: part, relativePath: built, isDirectory: !isLast)
                parent.children.append(node)
                lookup[built] = node
                parent = node
            }
        }
        func sort(_ node: InspectorFileNode) {
            node.children.sort {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            node.children.forEach(sort)
        }
        sort(top)
        return top.children
    }
}

private final class FilesOutlineView: NSOutlineView {
    var onOpen: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onOpen?()
            return
        }
        super.keyDown(with: event)
    }
}

final class InspectorFilesPane: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    private let outline = FilesOutlineView()
    private let scrollView = NSScrollView()
    private let footer = NSTextField(labelWithString: "")
    private let message = InspectorMessageLabel(frame: .zero)
    private var nodes = [InspectorFileNode]()
    private var directory: String?
    private var root: String?
    private var generation = 0
    private var loaded = false
    private var isVisibleInInspector = false

    override var isFlipped: Bool { true }
    var focusView: NSView { outline }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Workspace.Inspector.Tab.Files", defaultValue: "Files", comment: "Inspector tab label"))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 24
        outline.indentationPerLevel = 14
        outline.backgroundColor = .clear
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(openClicked)
        outline.onOpen = { [weak self] in self?.openSelection() }
        outline.setAccessibilityLabel(String(localized: "Workspace.Inspector.Files.Tree.A11y", defaultValue: "Repository files", comment: "Accessibility label of the file tree"))
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        footer.font = .systemFont(ofSize: 11.5)
        footer.textColor = WorkspaceColor.textSecondary
        footer.isHidden = true
        [scrollView, footer, message].forEach(addSubview)
        message.isHidden = true
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) has not been implemented")
    }

    func setDirectory(_ newDirectory: String?) {
        guard newDirectory != directory else { return }
        directory = newDirectory
        root = nil
        nodes = []
        loaded = false
        generation += 1
        outline.reloadData()
        footer.isHidden = true
        if newDirectory == nil {
            show(message: noRepoText)
        } else {
            message.isHidden = true
            scrollView.isHidden = false
        }
        if isVisibleInInspector {
            load()
        }
    }

    func setVisibleInInspector(_ visible: Bool) {
        isVisibleInInspector = visible
        if visible, !loaded {
            load()
        }
    }

    private var noRepoText: String {
        return String(localized: "Workspace.Inspector.Files.NoRepo",
                      defaultValue: "This folder isn’t in a git repo, so there are no files to show.",
                      comment: "Shown in the inspector's Files tab when the session's folder has no git repository")
    }

    private func show(message text: String) {
        message.text = text
        message.isHidden = false
        scrollView.isHidden = true
        footer.isHidden = true
        needsLayout = true
    }

    private func load() {
        guard let directory, !loaded else { return }
        loaded = true
        let token = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let root = InspectorGit.repoRoot(for: directory)
            let result = root.flatMap { InspectorGit.files(root: $0) }
            let tree = result.map { InspectorFileNode.tree(from: $0.paths) } ?? []
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                guard let root else {
                    self.show(message: self.noRepoText)
                    return
                }
                guard let result else {
                    self.show(message: String(localized: "Workspace.Inspector.Files.Error",
                                              defaultValue: "Couldn’t read this repo’s files.",
                                              comment: "Shown in the inspector's Files tab when git fails"))
                    return
                }
                self.root = root
                self.nodes = tree
                self.outline.reloadData()
                if result.paths.isEmpty {
                    self.show(message: String(localized: "Workspace.Inspector.Files.Empty",
                                              defaultValue: "No files to show in this repo.",
                                              comment: "Shown in the inspector's Files tab when the repo has no files"))
                    return
                }
                self.message.isHidden = true
                self.scrollView.isHidden = false
                if result.truncated {
                    let count = NumberFormatter.localizedString(from: NSNumber(value: InspectorGit.maxFileEntries), number: .decimal)
                    self.footer.stringValue = String(localized: "Workspace.Inspector.Files.Truncated",
                                                     defaultValue: "Showing the first \(count) files.",
                                                     comment: "Footer of the file tree when the repo has more files than the inspector lists. The placeholder is a formatted number.")
                    self.footer.isHidden = false
                }
                self.needsLayout = true
            }
        }
    }

    // MARK: Actions

    private func url(for node: InspectorFileNode) -> URL? {
        guard let root else { return nil }
        return URL(fileURLWithPath: root).appendingPathComponent(node.relativePath)
    }

    private var targetNode: InspectorFileNode? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return row >= 0 ? outline.item(atRow: row) as? InspectorFileNode : nil
    }

    @objc private func openClicked() {
        openSelection()
    }

    private func openSelection() {
        guard let node = targetNode else { return }
        if node.isDirectory {
            if outline.isItemExpanded(node) {
                outline.collapseItem(node)
            } else {
                outline.expandItem(node)
            }
        } else if let url = url(for: node) {
            NSWorkspace.shared.open(url)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard targetNode != nil else { return }
        menu.addItem(withTitle: String(localized: "Workspace.Inspector.Files.Menu.Reveal", defaultValue: "Reveal in Finder", comment: "Context menu item in the file tree"),
                     action: #selector(revealInFinder), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Workspace.Inspector.Files.Menu.CopyPath", defaultValue: "Copy path", comment: "Context menu item in the file tree that copies the absolute path"),
                     action: #selector(copyPath), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Workspace.Inspector.Files.Menu.CopyRelativePath", defaultValue: "Copy relative path", comment: "Context menu item in the file tree that copies the path relative to the repo"),
                     action: #selector(copyRelativePath), keyEquivalent: "").target = self
    }

    @objc private func revealInFinder() {
        if let node = targetNode, let url = url(for: node) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @objc private func copyPath() {
        if let node = targetNode, let url = url(for: node) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
    }

    @objc private func copyRelativePath() {
        if let node = targetNode {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.relativePath, forType: .string)
        }
    }

    // MARK: Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        return (item as? InspectorFileNode)?.children.count ?? nodes.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        return (item as? InspectorFileNode)?.children[index] ?? nodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return (item as? InspectorFileNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? InspectorFileNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("FileCell")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let image = NSImageView()
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingMiddle
            label.font = .systemFont(ofSize: 12.5)
            image.translatesAutoresizingMaskIntoConstraints = false
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.addSubview(label)
            cell.imageView = image
            cell.textField = label
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.textField?.stringValue = node.name
        cell.textField?.textColor = WorkspaceColor.textPrimary
        cell.imageView?.image = workspaceSymbolImage(node.isDirectory ? .folder : .doc, pointSize: 12)
        cell.imageView?.contentTintColor = node.isDirectory ? WorkspaceColor.accentText : WorkspaceColor.textSecondary
        cell.setAccessibilityLabel(node.name)
        return cell
    }

    override func layout() {
        super.layout()
        let footerHeight: CGFloat = footer.isHidden ? 0 : 24
        scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - footerHeight))
        footer.frame = NSRect(x: 14, y: bounds.height - footerHeight + 4, width: max(0, bounds.width - 28), height: 16)
        message.frame = bounds
        outline.tableColumns.first?.width = bounds.width
    }
}
