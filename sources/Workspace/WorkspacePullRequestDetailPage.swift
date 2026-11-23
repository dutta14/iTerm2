//
//  WorkspacePullRequestDetailPage.swift
//  iTerm2SharedARC
//
//  Read-only detail of one pull request: header, description, reviewers, assignees, labels and
//  checks. Starting a session from here checks the branch out first.
//

import AppKit

final class PullRequestDetailPage: NSView {
    weak var delegate: WorkspacePageDelegate?
    var onBack: (() -> Void)?
    private(set) var repo: String
    private(set) var number: Int
    private let scrollView = NSScrollView()
    private let content = NSStackView()
    private let message = WorkspaceMessageView(frame: .zero)
    private var detail: PullRequestDetail?
    private var generation = 0
    private static let maxDescriptionCharacters = 20_000

    init(repo: String, number: Int) {
        self.repo = repo
        self.number = number
        super.init(frame: .zero)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        let width = content.widthAnchor.constraint(equalToConstant: 760)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -32),
            content.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: 24),
            width
        ])
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor).isActive = true
        document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor).isActive = true
        document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor).isActive = true
        message.translatesAutoresizingMaskIntoConstraints = false
        message.isHidden = true
        addSubview(scrollView)
        addSubview(message)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            message.topAnchor.constraint(equalTo: topAnchor),
            message.bottomAnchor.constraint(equalTo: bottomAnchor),
            message.leadingAnchor.constraint(equalTo: leadingAnchor),
            message.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        message.onRetry = { [weak self] in
            GitHubClient.shared.forgetGHPath()
            self?.reload()
        }
    }

    required init?(coder: NSCoder) {
        it_fatalError("Not supported")
    }

    var viewName: String {
        return "#\(number)"
    }

    func reload() {
        generation += 1
        let token = generation
        if detail == nil {
            scrollView.isHidden = true
            message.isHidden = false
            message.showLoading(String(localized: "Workspace.PullRequests.Loading.A11y", defaultValue: "Loading pull requests", comment: "Accessibility label while pull requests load"))
        }
        GitHubClient.shared.pullRequestDetail(repo: repo, number: number) { [weak self] result in
            guard let self, token == self.generation else { return }
            switch result {
            case .success(let detail):
                self.detail = detail
                self.scrollView.isHidden = false
                self.message.isHidden = true
                self.rebuild(detail)
            case .failure(let error):
                guard self.detail == nil else { return }
                let info = WorkspaceSetupMessage.content(for: error)
                self.scrollView.isHidden = true
                self.message.isHidden = false
                self.message.show(heading: info.heading, body: info.body, command: info.command, retryTitle: info.retry)
            }
        }
    }

    // MARK: Building

    private func rebuild(_ detail: PullRequestDetail) {
        for view in content.arrangedSubviews {
            content.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let back = NSButton(title: String(localized: "Workspace.PullRequests.Back", defaultValue: "Pull requests", comment: "Link at the top of pull request details that returns to the list"),
                            target: self, action: #selector(backTapped))
        back.isBordered = false
        back.image = workspaceSymbolImage(.chevronLeft, pointSize: 11, weight: .semibold)
        back.imagePosition = .imageLeading
        back.contentTintColor = WorkspaceColor.accentText
        back.setAccessibilityLabel(String(localized: "Workspace.PullRequests.Back.A11y", defaultValue: "Back to pull requests", comment: "Accessibility label of the link that returns to the pull request list"))
        add(back)

        add(label("\(detail.title) #\(detail.number)", font: .systemFont(ofSize: 20, weight: .semibold), color: WorkspaceColor.textPrimary, wraps: true))

        let author = detail.author?.login ?? ""
        let date = DateFormatter.localizedString(from: detail.createdAt, dateStyle: .medium, timeStyle: .none)
        let repo = self.repo
        add(label(String(localized: "Workspace.PRDetail.Meta", defaultValue: "Opened by \(author) in \(repo) on \(date)", comment: "Details line of a pull request. Placeholders: author, repository, date."),
                  font: .systemFont(ofSize: 12), color: WorkspaceColor.textSecondary, wraps: true))
        add(label("\(detail.headRefName) → \(detail.baseRefName)",
                  font: .monospacedSystemFont(ofSize: 12, weight: .regular), color: WorkspaceColor.textSecondaryStrong, wraps: true))

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let state = detail.state.uppercased()
        let start = NSButton(title: String(localized: "Workspace.PullRequests.Action.Start", defaultValue: "Start session on this PR", comment: "Row button that starts a Copilot session on a pull request"),
                             target: self, action: #selector(startTapped))
        start.bezelStyle = .rounded
        if state != "OPEN" {
            start.isEnabled = false
            start.toolTip = state == "MERGED"
                ? String(localized: "Workspace.PRDetail.Disabled.Merged", defaultValue: "Merged pull requests can’t start a session.", comment: "Tooltip on the disabled start button of a merged pull request")
                : String(localized: "Workspace.PRDetail.Disabled.Closed", defaultValue: "Closed pull requests can’t start a session. Reopen it on GitHub first.", comment: "Tooltip on the disabled start button of a closed pull request")
        }
        let web = NSButton(title: String(localized: "Workspace.PRDetail.OpenOnGitHub", defaultValue: "Open on GitHub", comment: "Opens the item in the browser"),
                           target: self, action: #selector(webTapped))
        web.bezelStyle = .rounded
        buttons.addArrangedSubview(start)
        buttons.addArrangedSubview(web)
        add(buttons)

        section(String(localized: "Workspace.PRDetail.Section.Description", defaultValue: "Description", comment: "Section heading in pull request details"))
        add(descriptionView(detail.body))

        section(String(localized: "Workspace.PRDetail.Section.Reviewers", defaultValue: "Reviewers", comment: "Section heading in pull request details"))
        if detail.reviews.isEmpty {
            add(label(String(localized: "Workspace.PRDetail.Empty.Reviews", defaultValue: "No reviews yet.", comment: "Shown when a pull request has no reviews"), font: .systemFont(ofSize: 13), color: WorkspaceColor.textSecondary))
        }
        for review in detail.reviews {
            add(label("\(review.author?.login ?? "") · \(Self.reviewText(review.state))", font: .systemFont(ofSize: 13), color: WorkspaceColor.textPrimary))
        }

        if !detail.assignees.isEmpty {
            section(String(localized: "Workspace.PRDetail.Section.Assignees", defaultValue: "Assignees", comment: "Section heading in pull request details"))
            add(label(detail.assignees.map { $0.login }.joined(separator: ", "), font: .systemFont(ofSize: 13), color: WorkspaceColor.textPrimary, wraps: true))
        }
        if !detail.labels.isEmpty {
            section(String(localized: "Workspace.PRDetail.Section.Labels", defaultValue: "Labels", comment: "Section heading in pull request details"))
            add(label(detail.labels.map { $0.name }.joined(separator: ", "), font: .systemFont(ofSize: 13), color: WorkspaceColor.textPrimary, wraps: true))
        }

        section(String(localized: "Workspace.PRDetail.Section.Checks", defaultValue: "Checks", comment: "Section heading in pull request details"))
        if detail.statusCheckRollup.isEmpty {
            add(label(String(localized: "Workspace.PRDetail.Empty.Checks", defaultValue: "No checks have run.", comment: "Shown when a pull request has no checks"), font: .systemFont(ofSize: 13), color: WorkspaceColor.textSecondary))
        }
        for check in detail.statusCheckRollup {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            let icon = NSImageView()
            let symbol: SFSymbol
            switch check.outcome {
            case .passing:
                symbol = .checkmarkCircleFill
                icon.contentTintColor = WorkspaceColor.success
            case .failing:
                symbol = .xmarkCircleFill
                icon.contentTintColor = WorkspaceColor.danger
            case .running:
                symbol = .clock
                icon.contentTintColor = WorkspaceColor.warning
            case .neutral:
                symbol = .circleDashed
                icon.contentTintColor = WorkspaceColor.textSecondary
            }
            icon.image = workspaceSymbolImage(symbol, pointSize: 13)
            row.addArrangedSubview(icon)
            row.addArrangedSubview(label(check.displayName, font: .systemFont(ofSize: 13), color: WorkspaceColor.textPrimary))
            add(row)
        }
    }

    private static func reviewText(_ state: String) -> String {
        switch state.uppercased() {
        case "APPROVED":
            return String(localized: "Workspace.PRDetail.Review.Approved", defaultValue: "Approved", comment: "Review state")
        case "CHANGES_REQUESTED":
            return String(localized: "Workspace.PRDetail.Review.ChangesRequested", defaultValue: "Changes requested", comment: "Review state")
        default:
            return String(localized: "Workspace.PRDetail.Review.Commented", defaultValue: "Commented", comment: "Review state")
        }
    }

    private func add(_ view: NSView) {
        content.addArrangedSubview(view)
    }

    private func section(_ title: String) {
        add(label(title, font: .systemFont(ofSize: 13, weight: .semibold), color: WorkspaceColor.textSecondaryStrong))
    }

    private func label(_ text: String, font: NSFont, color: NSColor, wraps: Bool = false) -> NSTextField {
        let field = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.isSelectable = true
        if wraps {
            field.preferredMaxLayoutWidth = 712
        }
        return field
    }

    /// Markdown with HTML removed. Long bodies are cut so the layout stays cheap.
    private func descriptionView(_ body: String) -> NSView {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return label(String(localized: "Workspace.PRDetail.Empty.Description", defaultValue: "No description provided.", comment: "Shown when a pull request has no description"),
                         font: .systemFont(ofSize: 13), color: WorkspaceColor.textSecondary)
        }
        let truncated = trimmed.count > Self.maxDescriptionCharacters
        let text = Self.stripHTML(String(trimmed.prefix(Self.maxDescriptionCharacters)))
        let field = label("", font: .systemFont(ofSize: 13), color: WorkspaceColor.textPrimary, wraps: true)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: options) {
            let mutable = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
            let range = NSRange(location: 0, length: mutable.length)
            mutable.addAttribute(.font, value: NSFont.systemFont(ofSize: 13), range: range)
            mutable.addAttribute(.foregroundColor, value: WorkspaceColor.textPrimary, range: range)
            field.attributedStringValue = mutable
        } else {
            field.stringValue = text
        }
        guard truncated else { return field }
        let note = label(String(localized: "Workspace.PRDetail.Truncated", defaultValue: "This description is long, so it’s cut here. Read the rest on GitHub.", comment: "Shown under a pull request description that was shortened"),
                         font: .systemFont(ofSize: 12), color: WorkspaceColor.textSecondary, wraps: true)
        let stack = NSStackView(views: [field, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    static func stripHTML(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    // MARK: Actions

    @objc private func backTapped() {
        onBack?()
    }

    @objc private func startTapped() {
        delegate?.workspacePage(startSessionOnPullRequest: repo, number: number, title: detail?.title ?? "")
    }

    @objc private func webTapped() {
        if let url = detail.flatMap({ URL(string: $0.url) }) {
            NSWorkspace.shared.open(url)
        }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
