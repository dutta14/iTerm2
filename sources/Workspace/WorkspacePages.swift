//
//  WorkspacePages.swift
//  iTerm2SharedARC
//
//  The data-backed pages shown full-window: Pull requests, Issues and Automations. Each wraps a
//  WorkspaceListPage and talks to GitHub through GitHubClient. Cached results render first, the
//  refresh replaces them, and a failed refresh keeps the older rows with a notice.
//

import AppKit

protocol WorkspacePageDelegate: AnyObject {
    func workspacePage(startSessionOnPullRequest repo: String, number: Int, title: String)
    func workspacePage(startSessionOnIssue repo: String, number: Int, title: String)
    func workspacePage(showPullRequest repo: String, number: Int)
    func workspacePageKnownRepos() -> [String]
    func workspacePage(showLogTitled title: String, text: String)
    func workspacePage(copyToPasteboard text: String)
}

enum WorkspaceFormat {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    static func relative(_ date: Date, now: Date = Date()) -> String {
        if abs(now.timeIntervalSince(date)) < 45 {
            return String(localized: "Workspace.Time.JustNow", defaultValue: "just now", comment: "Relative time for something that happened less than a minute ago")
        }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = [.hour, .minute, .second]
        return formatter.string(from: max(1, seconds)) ?? ""
    }
}

enum WorkspaceSetupMessage {
    struct Content {
        var heading: String
        var body: String
        var command: String?
        var retry: String?
    }

    static func content(for error: GitHubError) -> Content {
        let checkAgain = String(localized: "Workspace.Setup.CheckAgain",
                                defaultValue: "Check again",
                                comment: "Button that re-checks whether the GitHub command line tool is ready")
        let tryAgain = String(localized: "Workspace.Setup.TryAgain",
                              defaultValue: "Try again",
                              comment: "Button that retries a failed GitHub request")
        switch error {
        case .ghMissing:
            return Content(heading: String(localized: "Workspace.Setup.GH.Missing.Heading",
                                           defaultValue: "GitHub CLI isn’t installed",
                                           comment: "Heading shown when the gh command is not installed"),
                           body: String(localized: "Workspace.Setup.GH.Missing.Body",
                                        defaultValue: "Dev Terminal uses GitHub CLI (`gh`) for pull requests, issues and runs. Install it, then check again.",
                                        comment: "Explains why GitHub CLI is needed"),
                           command: String(localized: "Workspace.Setup.GH.Missing.Command",
                                           defaultValue: "brew install gh",
                                           comment: "Shell command that installs GitHub CLI. Do not translate."),
                           retry: checkAgain)
        case .notAuthenticated:
            return Content(heading: String(localized: "Workspace.Setup.GH.Login.Heading",
                                           defaultValue: "Sign in to GitHub CLI",
                                           comment: "Heading shown when gh is not signed in"),
                           body: String(localized: "Workspace.Setup.GH.Login.Body",
                                        defaultValue: "`gh` isn’t signed in yet. Run this command in any terminal, then check again.",
                                        comment: "Explains how to sign in to GitHub CLI"),
                           command: String(localized: "Workspace.Setup.GH.Login.Command",
                                           defaultValue: "gh auth login",
                                           comment: "Shell command that signs in to GitHub CLI. Do not translate."),
                           retry: checkAgain)
        case .notAuthorized(let detail):
            return Content(heading: String(localized: "Workspace.Setup.GH.Auth.Heading",
                                           defaultValue: "GitHub CLI needs more access",
                                           comment: "Heading shown when GitHub denies access to a resource"),
                           body: String(localized: "Workspace.Setup.GH.Auth.Body",
                                        defaultValue: "GitHub blocked access to \(detail). Refresh your sign-in so `gh` can reach it, then check again.",
                                        comment: "Explains an authorization failure. The placeholder is the resource or message from GitHub."),
                           command: String(localized: "Workspace.Setup.GH.Auth.Command",
                                           defaultValue: "gh auth refresh",
                                           comment: "Shell command that refreshes GitHub CLI authorization. Do not translate."),
                           retry: checkAgain)
        case .offline:
            return Content(heading: String(localized: "Workspace.Setup.Offline.Heading",
                                           defaultValue: "GitHub can’t be reached",
                                           comment: "Heading shown when there is no network connection to GitHub"),
                           body: String(localized: "Workspace.Setup.Offline.Body",
                                        defaultValue: "Dev Terminal tries again when you’re back online. Cached results stay visible.",
                                        comment: "Explains what happens while offline"),
                           command: nil,
                           retry: tryAgain)
        case .rateLimited(let resetAt):
            let body: String
            if let resetAt {
                let time = DateFormatter.localizedString(from: resetAt, dateStyle: .none, timeStyle: .short)
                body = String(localized: "Workspace.Setup.RateLimit.Body.Reset",
                              defaultValue: "Requests resume at \(time). Cached results stay visible until then.",
                              comment: "Explains a GitHub rate limit. The placeholder is a time of day.")
            } else {
                body = String(localized: "Workspace.Setup.RateLimit.Body.NoReset",
                              defaultValue: "Requests resume in about 5 minutes. Cached results stay visible until then.",
                              comment: "Explains a GitHub rate limit when the reset time is unknown")
            }
            return Content(heading: String(localized: "Workspace.Setup.RateLimit.Heading",
                                           defaultValue: "GitHub rate limit reached",
                                           comment: "Heading shown when GitHub is rate limiting requests"),
                           body: body,
                           command: nil,
                           retry: tryAgain)
        case .timeout:
            return Content(heading: String(localized: "Workspace.Setup.Generic.Heading",
                                           defaultValue: "GitHub CLI returned an error",
                                           comment: "Heading shown when gh fails for an unrecognized reason"),
                           body: String(localized: "Workspace.Setup.Timeout",
                                        defaultValue: "GitHub took too long to respond. Try again in a moment.",
                                        comment: "Shown when a GitHub request times out"),
                           command: nil,
                           retry: tryAgain)
        case .failed(let detail):
            return Content(heading: String(localized: "Workspace.Setup.Generic.Heading",
                                           defaultValue: "GitHub CLI returned an error",
                                           comment: "Heading shown when gh fails for an unrecognized reason"),
                           body: String(localized: "Workspace.Setup.Generic.Body",
                                        defaultValue: "Here’s what it said: \(detail)",
                                        comment: "Shows the error text from GitHub CLI. The placeholder is that text."),
                           command: nil,
                           retry: tryAgain)
        }
    }

    static var couldntRefresh: String {
        return String(localized: "Workspace.Setup.CouldntRefresh",
                      defaultValue: "Couldn’t refresh. Showing older data.",
                      comment: "Shown above a list when the latest refresh failed and older results are displayed")
    }
}

// MARK: - Base

class WorkspaceDataPage: NSView {
    weak var delegate: WorkspacePageDelegate?
    let list = WorkspaceListPage(frame: .zero)
    private(set) var lastUpdated: Date?
    private var generation = 0
    private var lastError: GitHubError?

    override init(frame: NSRect) {
        super.init(frame: frame)
        list.translatesAutoresizingMaskIntoConstraints = false
        addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: topAnchor),
            list.bottomAnchor.constraint(equalTo: bottomAnchor),
            list.leadingAnchor.constraint(equalTo: leadingAnchor),
            list.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        list.onRefresh = { [weak self] in self?.reload() }
        list.messageView.onRetry = { [weak self] in
            GitHubClient.shared.forgetGHPath()
            self?.reload()
        }
        list.messageView.onCopy = { [weak self] in
            if let command = self?.lastCommand {
                self?.delegate?.workspacePage(copyToPasteboard: command)
            }
        }
    }

    required init?(coder: NSCoder) {
        it_fatalError("Not supported")
    }

    private var lastCommand: String?

    /// Starts a new load and returns its token. Responses carrying an older token are dropped.
    func beginLoad() -> Int {
        generation += 1
        return generation
    }

    func isCurrent(_ token: Int) -> Bool {
        return token == generation
    }

    func markUpdated() {
        lastUpdated = Date()
        lastError = nil
    }

    var footerUpdated: String {
        guard let lastUpdated else { return "" }
        let time = WorkspaceFormat.relative(lastUpdated)
        return String(localized: "Workspace.List.Footer.Updated",
                      defaultValue: "Updated \(time)",
                      comment: "Footer of a list showing when it was last refreshed. The placeholder is a relative time.")
    }

    func showLoading(_ accessibilityLabel: String) {
        list.showMessage()
        list.messageView.showLoading(accessibilityLabel)
    }

    func showEmpty(title: String, body: String, footer: String = "") {
        list.showMessage(footer: footer)
        list.messageView.show(heading: title, body: body)
    }

    func show(error: GitHubError, hasData: Bool) {
        lastError = error
        if hasData {
            list.showStale(WorkspaceSetupMessage.couldntRefresh)
            return
        }
        let content = WorkspaceSetupMessage.content(for: error)
        lastCommand = content.command
        list.showMessage()
        list.messageView.show(heading: content.heading,
                              body: content.body,
                              command: content.command,
                              retryTitle: content.retry)
    }

    // Subclasses override.
    func reload() {}
    func pageDidAppear() { reload() }
    func pageDidDisappear() {}
    var viewName: String { "" }
    var focusView: NSView? { list.focusView }
}

// MARK: - Pull requests

final class PullRequestsPage: WorkspaceDataPage {
    private var segment = PullRequestSegment.createdByMe
    private var stateFilter = GitHubItemState.open
    private var repoFilter: String?
    private var items = [PullRequestSummary]()
    private let states: [GitHubItemState] = [.open, .closed, .merged, .all]

    override var viewName: String {
        return String(localized: "Workspace.PullRequests.Title", defaultValue: "Pull requests", comment: "Title of the pull requests view")
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        list.setSegments([
            String(localized: "Workspace.PullRequests.Segment.Created", defaultValue: "Created by me", comment: "Segment showing pull requests the user opened"),
            String(localized: "Workspace.PullRequests.Segment.ReviewRequested", defaultValue: "Review requested", comment: "Segment showing pull requests awaiting the user's review"),
            String(localized: "Workspace.PullRequests.Segment.Mentioned", defaultValue: "Mentioned", comment: "Segment showing pull requests that mention the user")
        ], selected: 0)
        list.onSegmentChange = { [weak self] index in
            guard let self else { return }
            self.segment = PullRequestSegment.allCases[index]
            self.repoFilter = nil
            self.items = []
            self.reload()
        }
        list.onFilterChange = { [weak self] filter, index in
            guard let self else { return }
            if filter == 0 {
                let repos = self.availableRepos
                self.repoFilter = index == 0 || index > repos.count ? nil : repos[index - 1]
            } else {
                self.stateFilter = self.states[index]
                self.items = []
                self.reload()
                return
            }
            self.render()
        }
        list.onSelectRow = { [weak self] id in
            if let item = self?.item(for: id) {
                self?.delegate?.workspacePage(showPullRequest: item.repo, number: item.number)
            }
        }
        list.onAction = { [weak self] id, action in
            guard let self, let item = self.item(for: id) else { return }
            switch action {
            case "start":
                self.delegate?.workspacePage(startSessionOnPullRequest: item.repo, number: item.number, title: item.title)
            case "details":
                self.delegate?.workspacePage(showPullRequest: item.repo, number: item.number)
            case "web":
                if let url = URL(string: item.url) {
                    NSWorkspace.shared.open(url)
                }
            default:
                break
            }
        }
    }

    required init?(coder: NSCoder) {
        it_fatalError("Not supported")
    }

    private var availableRepos: [String] {
        return Array(Set(items.map { $0.repo })).sorted()
    }

    private func item(for id: String) -> PullRequestSummary? {
        return items.first { "\($0.repo)#\($0.number)" == id }
    }

    override func reload() {
        let token = beginLoad()
        let segment = segment
        let state = stateFilter
        if items.isEmpty, let cached = GitHubClient.shared.cachedPullRequests(segment: segment, state: state) {
            items = cached
            render()
        } else if items.isEmpty {
            showLoading(String(localized: "Workspace.PullRequests.Loading.A11y", defaultValue: "Loading pull requests", comment: "Accessibility label while pull requests load"))
        }
        GitHubClient.shared.pullRequests(segment: segment, state: state) { [weak self] result in
            guard let self, self.isCurrent(token) else { return }
            switch result {
            case .success(let fetched):
                self.items = fetched
                self.markUpdated()
                self.render()
            case .failure(let error):
                self.show(error: error, hasData: !self.items.isEmpty)
            }
        }
    }

    private func render() {
        let repos = availableRepos
        let allRepos = String(localized: "Workspace.Filter.AllRepos", defaultValue: "All repos", comment: "Filter option that shows every repository")
        list.setFilters([
            WorkspaceListFilter(title: String(localized: "Workspace.Filter.Repo", defaultValue: "Repository", comment: "Accessibility label of the repository filter"),
                                items: [allRepos] + repos,
                                selected: repoFilter.flatMap { repos.firstIndex(of: $0) }.map { $0 + 1 } ?? 0),
            WorkspaceListFilter(title: String(localized: "Workspace.Filter.State", defaultValue: "State", comment: "Accessibility label of the state filter"),
                                items: [String(localized: "Workspace.Filter.State.Open", defaultValue: "Open", comment: "State filter option"),
                                        String(localized: "Workspace.Filter.State.Closed", defaultValue: "Closed", comment: "State filter option"),
                                        String(localized: "Workspace.Filter.State.Merged", defaultValue: "Merged", comment: "State filter option"),
                                        String(localized: "Workspace.Filter.State.All", defaultValue: "All", comment: "State filter option")],
                                selected: states.firstIndex(of: stateFilter) ?? 0)
        ])
        let visible = items.filter { repoFilter == nil || $0.repo == repoFilter }
        guard !visible.isEmpty else {
            showEmptyState(filtered: !items.isEmpty || repoFilter != nil || stateFilter != .open)
            return
        }
        let startTitle = String(localized: "Workspace.PullRequests.Action.Start", defaultValue: "Start session on this PR", comment: "Row button that starts a Copilot session on a pull request")
        let detailsTitle = String(localized: "Workspace.PullRequests.Row.OpenDetails", defaultValue: "Open details", comment: "Context menu item that opens pull request details")
        let webTitle = String(localized: "Workspace.PRDetail.OpenOnGitHub", defaultValue: "Open on GitHub", comment: "Opens the item in the browser")
        let rows = visible.map { pr -> WorkspaceListRow in
            let time = WorkspaceFormat.relative(pr.updatedAt)
            let author = pr.author?.login ?? ""
            let lowered = pr.state.lowercased()
            let subtitle: String
            let symbol: SFSymbol
            let tint: NSColor
            if lowered == "merged" {
                subtitle = String(localized: "Workspace.PullRequests.Meta.Merged", defaultValue: "\(pr.repo) · \(author) · merged \(time)", comment: "Row details for a merged pull request: repository, author, time")
                symbol = .arrowTriangleMerge
                tint = WorkspaceColor.accentText
            } else if lowered == "closed" {
                subtitle = String(localized: "Workspace.PullRequests.Meta.Closed", defaultValue: "\(pr.repo) · \(author) · closed \(time)", comment: "Row details for a closed pull request: repository, author, time")
                symbol = .arrowTrianglePull
                tint = WorkspaceColor.danger
            } else {
                subtitle = String(localized: "Workspace.PullRequests.Meta.NoBranch", defaultValue: "\(pr.repo) · updated \(time)", comment: "Row details for an open pull request: repository, time")
                symbol = pr.isDraft ? .circleDashed : .arrowTrianglePull
                tint = pr.isDraft ? WorkspaceColor.textSecondary : WorkspaceColor.success
            }
            let canStart = lowered == "open"
            return WorkspaceListRow(id: "\(pr.repo)#\(pr.number)",
                                    symbol: symbol,
                                    tint: tint,
                                    title: pr.title,
                                    subtitle: subtitle,
                                    chips: pr.isDraft && lowered == "open" ? [String(localized: "Workspace.PullRequests.Draft", defaultValue: "Draft", comment: "Badge on a draft pull request")] : [],
                                    trailing: "#\(pr.number)",
                                    actions: canStart ? [WorkspaceListAction(identifier: "start", title: startTitle)] : [],
                                    menuActions: [WorkspaceListAction(identifier: "details", title: detailsTitle),
                                                  WorkspaceListAction(identifier: "web", title: webTitle)])
        }
        let footer = items.count >= GitHubClient.maxResults
            ? String(localized: "Workspace.List.Footer.Showing", defaultValue: "Showing the first \(GitHubClient.maxResults)", comment: "Footer when a list is truncated. The placeholder is a count.")
            : footerUpdated
        list.show(rows: rows, footer: footer == footerUpdated ? footer : "\(footer) · \(footerUpdated)", staleNotice: nil)
    }

    private func showEmptyState(filtered: Bool) {
        if filtered && (!items.isEmpty || repoFilter != nil || stateFilter != .open) {
            showEmpty(title: String(localized: "Workspace.PullRequests.Empty.NoMatch.Title", defaultValue: "No pull requests match these filters", comment: "Empty state title"),
                      body: String(localized: "Workspace.PullRequests.Empty.NoMatch.Body", defaultValue: "Try a different repo or state.", comment: "Empty state body"),
                      footer: footerUpdated)
            return
        }
        switch segment {
        case .createdByMe:
            showEmpty(title: String(localized: "Workspace.PullRequests.Empty.Created.Title", defaultValue: "No open pull requests", comment: "Empty state title"),
                      body: String(localized: "Workspace.PullRequests.Empty.Created.Body", defaultValue: "Pull requests you open appear here.", comment: "Empty state body"),
                      footer: footerUpdated)
        case .reviewRequested:
            showEmpty(title: String(localized: "Workspace.PullRequests.Empty.Review.Title", defaultValue: "Nothing to review", comment: "Empty state title"),
                      body: String(localized: "Workspace.PullRequests.Empty.Review.Body", defaultValue: "When someone asks for your review, it appears here.", comment: "Empty state body"),
                      footer: footerUpdated)
        case .mentioned:
            showEmpty(title: String(localized: "Workspace.PullRequests.Empty.Mentioned.Title", defaultValue: "No mentions", comment: "Empty state title"),
                      body: String(localized: "Workspace.PullRequests.Empty.Mentioned.Body", defaultValue: "Pull requests that mention you appear here.", comment: "Empty state body"),
                      footer: footerUpdated)
        }
    }
}

// MARK: - Issues

final class IssuesPage: WorkspaceDataPage {
    private var segment = IssueSegment.assignedToMe
    private var stateFilter = GitHubItemState.open
    private var repoFilter: String?
    private var items = [IssueSummary]()
    private let states: [GitHubItemState] = [.open, .closed, .all]

    override var viewName: String {
        return String(localized: "Workspace.Issues.Title", defaultValue: "Issues", comment: "Title of the issues view")
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        list.setSegments([
            String(localized: "Workspace.Issues.Segment.Assigned", defaultValue: "Assigned to me", comment: "Segment showing issues assigned to the user"),
            String(localized: "Workspace.Issues.Segment.Created", defaultValue: "Created by me", comment: "Segment showing issues the user opened"),
            String(localized: "Workspace.Issues.Segment.Mentioned", defaultValue: "Mentioned", comment: "Segment showing issues that mention the user")
        ], selected: 0)
        list.onSegmentChange = { [weak self] index in
            guard let self else { return }
            self.segment = IssueSegment.allCases[index]
            self.repoFilter = nil
            self.items = []
            self.reload()
        }
        list.onFilterChange = { [weak self] filter, index in
            guard let self else { return }
            if filter == 0 {
                let repos = self.availableRepos
                self.repoFilter = index == 0 || index > repos.count ? nil : repos[index - 1]
                self.render()
            } else {
                self.stateFilter = self.states[index]
                self.items = []
                self.reload()
            }
        }
        list.onSelectRow = { [weak self] id in
            if let item = self?.item(for: id), let url = URL(string: item.url) {
                NSWorkspace.shared.open(url)
            }
        }
        list.onAction = { [weak self] id, action in
            guard let self, let item = self.item(for: id) else { return }
            switch action {
            case "start":
                self.delegate?.workspacePage(startSessionOnIssue: item.repo, number: item.number, title: item.title)
            case "web":
                if let url = URL(string: item.url) {
                    NSWorkspace.shared.open(url)
                }
            default:
                break
            }
        }
    }

    required init?(coder: NSCoder) {
        it_fatalError("Not supported")
    }

    private var availableRepos: [String] {
        return Array(Set(items.map { $0.repository.nameWithOwner })).sorted()
    }

    private func item(for id: String) -> IssueSummary? {
        return items.first { "\($0.repo)#\($0.number)" == id }
    }

    override func reload() {
        let token = beginLoad()
        let segment = segment
        let state = stateFilter
        if items.isEmpty, let cached = GitHubClient.shared.cachedIssues(segment: segment, state: state) {
            items = cached
            render()
        } else if items.isEmpty {
            showLoading(String(localized: "Workspace.Issues.Loading.A11y", defaultValue: "Loading issues", comment: "Accessibility label while issues load"))
        }
        GitHubClient.shared.issues(segment: segment, state: state) { [weak self] result in
            guard let self, self.isCurrent(token) else { return }
            switch result {
            case .success(let fetched):
                self.items = fetched
                self.markUpdated()
                self.render()
            case .failure(let error):
                self.show(error: error, hasData: !self.items.isEmpty)
            }
        }
    }

    private func render() {
        let repos = availableRepos
        list.setFilters([
            WorkspaceListFilter(title: String(localized: "Workspace.Filter.Repo", defaultValue: "Repository", comment: "Accessibility label of the repository filter"),
                                items: [String(localized: "Workspace.Filter.AllRepos", defaultValue: "All repos", comment: "Filter option that shows every repository")] + repos,
                                selected: repoFilter.flatMap { repos.firstIndex(of: $0) }.map { $0 + 1 } ?? 0),
            WorkspaceListFilter(title: String(localized: "Workspace.Filter.State", defaultValue: "State", comment: "Accessibility label of the state filter"),
                                items: [String(localized: "Workspace.Filter.State.Open", defaultValue: "Open", comment: "State filter option"),
                                        String(localized: "Workspace.Filter.State.Closed", defaultValue: "Closed", comment: "State filter option"),
                                        String(localized: "Workspace.Filter.State.All", defaultValue: "All", comment: "State filter option")],
                                selected: states.firstIndex(of: stateFilter) ?? 0)
        ])
        let visible = items.filter { repoFilter == nil || $0.repo == repoFilter }
        guard !visible.isEmpty else {
            showEmptyState(filtered: repoFilter != nil || stateFilter != .open)
            return
        }
        let startTitle = String(localized: "Workspace.Issues.Action.Start", defaultValue: "Start session on this issue…", comment: "Row button that starts a Copilot session to fix an issue. The ellipsis means a confirmation sheet follows.")
        let webTitle = String(localized: "Workspace.PRDetail.OpenOnGitHub", defaultValue: "Open on GitHub", comment: "Opens the item in the browser")
        let rows = visible.map { issue -> WorkspaceListRow in
            let isOpen = issue.state.lowercased() == "open"
            let subtitle: String
            if isOpen {
                let time = WorkspaceFormat.relative(issue.createdAt)
                subtitle = String(localized: "Workspace.Issues.Meta.Open", defaultValue: "\(issue.repo) · opened \(time)", comment: "Row details for an open issue: repository, time")
            } else {
                let time = WorkspaceFormat.relative(issue.updatedAt)
                subtitle = String(localized: "Workspace.Issues.Meta.Closed", defaultValue: "\(issue.repo) · closed \(time)", comment: "Row details for a closed issue: repository, time")
            }
            let disabledTip = String(localized: "Workspace.Issues.Disabled.Closed", defaultValue: "Closed issues can’t start a session. Reopen it on GitHub first.", comment: "Tooltip on the disabled start button of a closed issue")
            return WorkspaceListRow(id: "\(issue.repo)#\(issue.number)",
                                    symbol: isOpen ? .circleDotted : .checkmarkCircleFill,
                                    tint: isOpen ? WorkspaceColor.success : WorkspaceColor.accentText,
                                    title: issue.title,
                                    subtitle: subtitle,
                                    chips: Array(issue.labels.prefix(2).map { $0.name }),
                                    trailing: "#\(issue.number)",
                                    actions: [WorkspaceListAction(identifier: "start", title: startTitle, enabled: isOpen, tooltip: isOpen ? nil : disabledTip)],
                                    menuActions: [WorkspaceListAction(identifier: "web", title: webTitle)])
        }
        let footer = items.count >= GitHubClient.maxResults
            ? String(localized: "Workspace.List.Footer.Showing", defaultValue: "Showing the first \(GitHubClient.maxResults)", comment: "Footer when a list is truncated. The placeholder is a count.") + " · " + footerUpdated
            : footerUpdated
        list.show(rows: rows, footer: footer, staleNotice: nil)
    }

    private func showEmptyState(filtered: Bool) {
        if filtered {
            showEmpty(title: String(localized: "Workspace.Issues.Empty.NoMatch.Title", defaultValue: "No issues match these filters", comment: "Empty state title"),
                      body: String(localized: "Workspace.Issues.Empty.NoMatch.Body", defaultValue: "Try a different repo or state.", comment: "Empty state body"),
                      footer: footerUpdated)
            return
        }
        switch segment {
        case .assignedToMe:
            showEmpty(title: String(localized: "Workspace.Issues.Empty.Assigned.Title", defaultValue: "No open issues assigned to you", comment: "Empty state title"),
                      body: String(localized: "Workspace.Issues.Empty.Assigned.Body", defaultValue: "Issues assigned to you appear here.", comment: "Empty state body"),
                      footer: footerUpdated)
        case .createdByMe:
            showEmpty(title: String(localized: "Workspace.Issues.Empty.Created.Title", defaultValue: "You have no open issues", comment: "Empty state title"),
                      body: String(localized: "Workspace.Issues.Empty.Created.Body", defaultValue: "Issues you open appear here.", comment: "Empty state body"),
                      footer: footerUpdated)
        case .mentioned:
            showEmpty(title: String(localized: "Workspace.Issues.Empty.Mentioned.Title", defaultValue: "No mentions", comment: "Empty state title"),
                      body: String(localized: "Workspace.Issues.Empty.Mentioned.Body", defaultValue: "Issues that mention you appear here.", comment: "Empty state body"),
                      footer: footerUpdated)
        }
    }
}

// MARK: - Automations

final class AutomationsPage: WorkspaceDataPage {
    private enum Filter: Int, CaseIterable {
        case all, running, failed
    }

    private static let runsPerRepo = 15
    private var filter = Filter.all
    private var repoRuns = [GitHubClient.RepoRuns]()
    private var runs = [WorkflowRun]()
    private var timer: Timer?
    private var pendingActions = [Int: String]()
    private var actionError: String?

    override var viewName: String {
        return String(localized: "Workspace.Automations.Title", defaultValue: "Automations", comment: "Title of the automations view")
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        list.setSegments([
            String(localized: "Workspace.Automations.Filter.All", defaultValue: "All runs", comment: "Filter showing every workflow run"),
            String(localized: "Workspace.Automations.Filter.Running", defaultValue: "Running", comment: "Filter showing runs in progress"),
            String(localized: "Workspace.Automations.Filter.Failed", defaultValue: "Failed", comment: "Filter showing failed runs")
        ], selected: 0)
        list.setFilters([])
        list.onSegmentChange = { [weak self] index in
            self?.filter = Filter(rawValue: index) ?? .all
            self?.render()
        }
        list.onSelectRow = { [weak self] id in
            if let run = self?.run(for: id), let url = URL(string: run.url) {
                NSWorkspace.shared.open(url)
            }
        }
        list.onAction = { [weak self] id, action in
            guard let self, let run = self.run(for: id) else { return }
            switch action {
            case "cancel":
                self.confirmCancel(run)
            case "rerun":
                self.rerun(run)
            case "log":
                self.viewLog(run)
            case "web":
                if let url = URL(string: run.url) {
                    NSWorkspace.shared.open(url)
                }
            default:
                break
            }
        }
    }

    required init?(coder: NSCoder) {
        it_fatalError("Not supported")
    }

    deinit {
        timer?.invalidate()
    }

    private func run(for id: String) -> WorkflowRun? {
        return runs.first { String($0.databaseId) == id }
    }

    override func pageDidAppear() {
        super.pageDidAppear()
        scheduleTimer()
    }

    override func pageDidDisappear() {
        timer?.invalidate()
        timer = nil
    }

    // 10 s while something is running, 60 s otherwise.
    private func scheduleTimer() {
        timer?.invalidate()
        let interval: TimeInterval = runs.contains { $0.isInProgress } ? 10 : 60
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.reload()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func reload() {
        let repos = delegate?.workspacePageKnownRepos() ?? []
        guard !repos.isEmpty else {
            showEmpty(title: String(localized: "Workspace.Automations.Empty.NoRepos.Title", defaultValue: "No repos to watch", comment: "Empty state title"),
                      body: String(localized: "Workspace.Automations.Empty.NoRepos.Body", defaultValue: "Start a session in a repo or open a pull request and its runs appear here.", comment: "Empty state body"))
            return
        }
        let token = beginLoad()
        if runs.isEmpty {
            showLoading(String(localized: "Workspace.Automations.Loading.A11y", defaultValue: "Loading workflow runs", comment: "Accessibility label while workflow runs load"))
        }
        GitHubClient.shared.runs(repos: repos) { [weak self] results in
            guard let self, self.isCurrent(token) else { return }
            self.repoRuns = results
            var merged = [WorkflowRun]()
            var firstError: GitHubError?
            for result in results {
                switch result.result {
                case .success(let items):
                    merged.append(contentsOf: items.prefix(Self.runsPerRepo))
                case .failure(let error):
                    firstError = firstError ?? error
                }
            }
            if let firstError, merged.isEmpty {
                self.show(error: firstError, hasData: !self.runs.isEmpty)
            } else {
                self.runs = merged
                self.markUpdated()
                self.render(stale: firstError != nil)
            }
            if self.superview != nil, self.timer != nil || self.window != nil {
                self.scheduleTimer()
            }
        }
    }

    private func render(stale: Bool = false) {
        var visible = runs
        switch filter {
        case .all: break
        case .running: visible = visible.filter { $0.isInProgress }
        case .failed: visible = visible.filter { $0.isFailed }
        }
        visible.sort {
            if $0.isInProgress != $1.isInProgress {
                return $0.isInProgress
            }
            return $0.updatedAt > $1.updatedAt
        }
        guard !visible.isEmpty else {
            switch filter {
            case .all:
                showEmpty(title: String(localized: "Workspace.Automations.Empty.None.Title", defaultValue: "No workflow runs yet", comment: "Empty state title"),
                          body: String(localized: "Workspace.Automations.Empty.None.Body", defaultValue: "Runs from GitHub Actions appear here once your repos have run a workflow.", comment: "Empty state body"),
                          footer: footerUpdated)
            case .running:
                showEmpty(title: String(localized: "Workspace.Automations.Empty.NoRunning.Title", defaultValue: "Nothing running", comment: "Empty state title"),
                          body: String(localized: "Workspace.Automations.Empty.NoRunning.Body", defaultValue: "Running workflows appear here while they run.", comment: "Empty state body"),
                          footer: footerUpdated)
            case .failed:
                let count = Self.runsPerRepo
                showEmpty(title: String(localized: "Workspace.Automations.Empty.NoFailed.Title", defaultValue: "No failed runs", comment: "Empty state title"),
                          body: String(localized: "Workspace.Automations.Empty.NoFailed.Body", defaultValue: "None of the latest \(count) runs per repo failed.", comment: "Empty state body. The placeholder is a count."),
                          footer: footerUpdated)
            }
            return
        }
        let cancelTitle = String(localized: "Workspace.Automations.Action.Cancel", defaultValue: "Cancel", comment: "Row button that cancels a running workflow")
        let rerunTitle = String(localized: "Workspace.Automations.Action.Rerun", defaultValue: "Re-run", comment: "Row button that re-runs a workflow")
        let logTitle = String(localized: "Workspace.Automations.Action.ViewLog", defaultValue: "View log", comment: "Row button that shows the failed log of a workflow run")
        let webTitle = String(localized: "Workspace.PRDetail.OpenOnGitHub", defaultValue: "Open on GitHub", comment: "Opens the item in the browser")
        let rows = visible.map { run -> WorkspaceListRow in
            let pending = pendingActions[run.databaseId]
            var actions = [WorkspaceListAction]()
            if run.isInProgress {
                actions.append(WorkspaceListAction(identifier: "cancel", title: cancelTitle, enabled: pending == nil))
            } else {
                actions.append(WorkspaceListAction(identifier: "rerun", title: rerunTitle, enabled: pending == nil))
                if run.isFailed {
                    actions.insert(WorkspaceListAction(identifier: "log", title: logTitle), at: 0)
                }
            }
            return WorkspaceListRow(id: String(run.databaseId),
                                    symbol: Self.symbol(for: run),
                                    tint: Self.tint(for: run),
                                    title: run.title,
                                    subtitle: Self.subtitle(for: run),
                                    trailing: pending ?? Self.statusText(for: run),
                                    trailingTint: Self.tint(for: run),
                                    actions: actions,
                                    menuActions: [WorkspaceListAction(identifier: "web", title: webTitle)])
        }
        list.show(rows: rows,
                  footer: footerUpdated + " · " + String(localized: "Workspace.Automations.Cadence", defaultValue: "Updates every 10 seconds while open", comment: "Footer note describing how often runs refresh while a run is in progress"),
                  staleNotice: actionError ?? (stale ? WorkspaceSetupMessage.couldntRefresh : nil))
    }

    private static func symbol(for run: WorkflowRun) -> SFSymbol {
        if run.isInProgress { return run.status == "in_progress" ? .arrowTriangle2Circlepath : .clock }
        if run.isFailed { return .xmarkCircleFill }
        if run.conclusion == "success" { return .checkmarkCircleFill }
        return .circleDashed
    }

    private static func tint(for run: WorkflowRun) -> NSColor {
        if run.isInProgress { return WorkspaceColor.warning }
        if run.isFailed { return WorkspaceColor.danger }
        if run.conclusion == "success" { return WorkspaceColor.success }
        return WorkspaceColor.textSecondary
    }

    private static func statusText(for run: WorkflowRun) -> String {
        if run.isInProgress {
            switch run.status {
            case "queued":
                return String(localized: "Workspace.Automations.Status.Queued", defaultValue: "Queued", comment: "Status of a workflow run waiting to start")
            case "waiting":
                return String(localized: "Workspace.Automations.Status.Waiting", defaultValue: "Waiting", comment: "Status of a workflow run waiting for approval")
            default:
                return String(localized: "Workspace.Automations.Status.Running", defaultValue: "Running", comment: "Status of a workflow run in progress")
            }
        }
        if run.isFailed {
            return String(localized: "Workspace.Automations.Status.Failed", defaultValue: "Failed", comment: "Status of a failed workflow run")
        }
        if run.conclusion == "success" {
            return String(localized: "Workspace.Automations.Status.Succeeded", defaultValue: "Succeeded", comment: "Status of a successful workflow run")
        }
        return String(localized: "Workspace.Automations.State.Cancelled", defaultValue: "Cancelled", comment: "Status of a cancelled workflow run")
    }

    private static func subtitle(for run: WorkflowRun) -> String {
        let branch = run.headBranch ?? ""
        if run.isInProgress {
            let time = WorkspaceFormat.relative(run.createdAt)
            return String(localized: "Workspace.Automations.Meta.Running", defaultValue: "\(run.repo) · \(branch) · running \(time)", comment: "Row details for a running workflow: repository, branch, time since start")
        }
        let status = statusText(for: run)
        let duration = WorkspaceFormat.duration(run.updatedAt.timeIntervalSince(run.createdAt))
        let time = WorkspaceFormat.relative(run.updatedAt)
        return String(localized: "Workspace.Automations.Meta.Finished", defaultValue: "\(run.repo) · \(branch) · \(status) in \(duration) · \(time)", comment: "Row details for a finished workflow: repository, branch, status, duration, time since finish")
    }

    // MARK: Actions

    private func confirmCancel(_ run: WorkflowRun) {
        let warning = iTermWarning()
        warning.heading = String(localized: "Workspace.Automations.Cancel.Title", defaultValue: "Cancel this run?", comment: "Title of the confirmation before cancelling a workflow run")
        let name = run.title
        let repo = run.repo
        warning.title = String(localized: "Workspace.Automations.Cancel.Body", defaultValue: "\(name) in \(repo) will be cancelled. You can re-run it later.", comment: "Body of the confirmation before cancelling a workflow run. Placeholders: run name, repository.")
        let confirm = String(localized: "Workspace.Automations.Cancel.Confirm", defaultValue: "Cancel run", comment: "Button that cancels the run")
        let dismiss = String(localized: "Workspace.Automations.Cancel.Dismiss", defaultValue: "Keep running", comment: "Button that leaves the run going")
        warning.actionLabels = [confirm, dismiss]
        warning.cancelLabel = dismiss
        warning.warningType = .kiTermWarningTypePersistent
        warning.window = window
        guard warning.runModal() == .kiTermWarningSelection0 else { return }
        actionError = nil
        pendingActions[run.databaseId] = String(localized: "Workspace.Automations.State.Cancelling", defaultValue: "Cancelling…", comment: "Shown on a row while its run is being cancelled")
        render()
        GitHubClient.shared.perform(.cancel, runId: run.databaseId, repo: run.repo) { [weak self] result in
            self?.finishAction(run: run, result: result)
        }
    }

    private func rerun(_ run: WorkflowRun) {
        actionError = nil
        pendingActions[run.databaseId] = String(localized: "Workspace.Automations.State.Rerunning", defaultValue: "Re-running…", comment: "Shown on a row while its run is being started again")
        render()
        GitHubClient.shared.perform(.rerun(failedOnly: run.isFailed), runId: run.databaseId, repo: run.repo) { [weak self] result in
            self?.finishAction(run: run, result: result)
        }
    }

    private func finishAction(run: WorkflowRun, result: Result<Void, GitHubError>) {
        pendingActions[run.databaseId] = nil
        if case .failure(let error) = result {
            actionError = WorkspaceSetupMessage.content(for: error).body
        }
        reload()
    }

    private func viewLog(_ run: WorkflowRun) {
        let title = run.title
        GitHubClient.shared.failedLog(runId: run.databaseId, repo: run.repo) { [weak self] result in
            switch result {
            case .success(let text):
                self?.delegate?.workspacePage(showLogTitled: title, text: text.isEmpty ? "—" : text)
            case .failure(let error):
                self?.list.showStale(WorkspaceSetupMessage.content(for: error).body)
            }
        }
    }
}
