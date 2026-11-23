//
//  WorkspaceFullWindowHost.swift
//  iTerm2SharedARC
//
//  Covers the terminal area with a full-window view (Pull requests, Issues, Automations or a pull
//  request's details). The terminal sessions underneath keep running. Keeps a back/forward history
//  of the views visited and returns to the session on Esc.
//

import AppKit

enum WorkspaceDestination: Equatable {
    case pullRequests
    case issues
    case automations
    case pullRequestDetail(repo: String, number: Int)

    var navItem: WorkspaceNavItem {
        switch self {
        case .pullRequests, .pullRequestDetail: return .pullRequests
        case .issues: return .issues
        case .automations: return .automations
        }
    }
}

final class WorkspaceFullWindowHost: NSView {
    static let maxHistory = 50

    weak var pageDelegate: WorkspacePageDelegate? {
        didSet {
            pullRequestsPage.delegate = pageDelegate
            issuesPage.delegate = pageDelegate
            automationsPage.delegate = pageDelegate
        }
    }
    var onClose: (() -> Void)?
    var onDestinationChange: (() -> Void)?

    private(set) var destination: WorkspaceDestination?
    private var history = [WorkspaceDestination]()
    private var historyIndex = -1
    private let pullRequestsPage = PullRequestsPage(frame: .zero)
    private let issuesPage = IssuesPage(frame: .zero)
    private let automationsPage = AutomationsPage(frame: .zero)
    private var detailPage: PullRequestDetailPage?
    private var visiblePage: NSView?
    private var logPanel: NSWindow?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) {
        it_fatalError("Not supported")
    }

    var viewName: String? {
        switch destination {
        case .pullRequests: return pullRequestsPage.viewName
        case .issues: return issuesPage.viewName
        case .automations: return automationsPage.viewName
        case .pullRequestDetail(_, let number):
            let name = String(localized: "Workspace.PullRequests.Title", defaultValue: "Pull requests", comment: "Title of the pull requests view")
            return "\(name) · #\(number)"
        case nil: return nil
        }
    }

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex >= 0 && historyIndex < history.count - 1 }

    // MARK: Navigation

    func show(_ new: WorkspaceDestination) {
        if destination == new, visiblePage != nil {
            reloadVisiblePage()
            return
        }
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(new)
        if history.count > Self.maxHistory {
            history.removeFirst(history.count - Self.maxHistory)
        }
        historyIndex = history.count - 1
        display(new)
    }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        display(history[historyIndex])
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        display(history[historyIndex])
    }

    func reset() {
        visiblePage.map(pageDidDisappear)
        visiblePage?.removeFromSuperview()
        visiblePage = nil
        destination = nil
        history = []
        historyIndex = -1
        detailPage = nil
    }

    private func display(_ new: WorkspaceDestination) {
        visiblePage.map(pageDidDisappear)
        visiblePage?.removeFromSuperview()
        destination = new
        let page: NSView
        switch new {
        case .pullRequests: page = pullRequestsPage
        case .issues: page = issuesPage
        case .automations: page = automationsPage
        case .pullRequestDetail(let repo, let number):
            let detail = PullRequestDetailPage(repo: repo, number: number)
            detail.delegate = pageDelegate
            detail.onBack = { [weak self] in self?.goBackOrShowList() }
            detailPage = detail
            page = detail
        }
        page.frame = bounds
        page.autoresizingMask = [.width, .height]
        addSubview(page)
        visiblePage = page
        reloadVisiblePage(initial: true)
        onDestinationChange?()
        window?.makeFirstResponder((page as? WorkspaceDataPage)?.focusView ?? page)
    }

    private func goBackOrShowList() {
        if canGoBack {
            goBack()
        } else {
            show(.pullRequests)
        }
    }

    private func reloadVisiblePage(initial: Bool = false) {
        if let page = visiblePage as? WorkspaceDataPage {
            if initial {
                page.pageDidAppear()
            } else {
                page.reload()
            }
        } else if let detail = visiblePage as? PullRequestDetailPage {
            detail.reload()
        }
    }

    private func pageDidDisappear(_ page: NSView) {
        (page as? WorkspaceDataPage)?.pageDidDisappear()
    }

    // MARK: Events

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = WorkspaceColor.windowBackground.cgColor
        }
    }

    override var isOpaque: Bool { true }

    // MARK: Log sheet

    func presentLog(title: String, text: String) {
        guard let parent = window else { return }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                             styleMask: [.titled, .resizable],
                             backing: .buffered,
                             defer: false)
        panel.title = String(localized: "Workspace.Automations.Log.Title", defaultValue: "Run log", comment: "Title of the sheet that shows a workflow run's log") + " · " + title
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 44, width: 760, height: 476))
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = text
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        let copy = NSButton(title: String(localized: "Workspace.Setup.Copy", defaultValue: "Copy", comment: "Button that copies a command to the clipboard"),
                            target: self, action: #selector(copyLog(_:)))
        copy.frame = NSRect(x: 16, y: 10, width: 80, height: 24)
        copyText = text
        let close = NSButton(title: String(localized: "Workspace.Log.Close", defaultValue: "Close", comment: "Button that closes the run log sheet"),
                             target: self, action: #selector(closeLog))
        close.frame = NSRect(x: 664, y: 10, width: 80, height: 24)
        close.autoresizingMask = [.minXMargin]
        close.keyEquivalent = "\u{1b}"
        panel.contentView?.addSubview(scroll)
        panel.contentView?.addSubview(copy)
        panel.contentView?.addSubview(close)
        logPanel = panel
        parent.beginSheet(panel)
    }

    private var copyText = ""

    @objc private func copyLog(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
    }

    @objc private func closeLog() {
        if let panel = logPanel {
            window?.endSheet(panel)
        }
        logPanel = nil
    }
}
