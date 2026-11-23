//
//  InspectorPullRequestPane.swift
//  iTerm2SharedARC
//
//  The inspector's pull request tab: Description, Files, Reviews and Checks for the pull request
//  of the active session's branch. Read-only; it shares its data with the full-window detail page.
//

import AppKit

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// A borderless button that reads like a row and opens a URL.
private final class LinkRowButton: NSButton {
    var url: URL?
}

final class InspectorPullRequestPane: NSView {
    private enum Section: Int, CaseIterable {
        case description, files, reviews, checks
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let webButton = NSButton()
    private let refreshButton = NSButton()
    private let segments = NSSegmentedControl()
    private let scrollView = NSScrollView()
    private let content = NSStackView()
    private let message = InspectorMessageLabel(frame: .zero)
    private let separator = NSView()

    private var state = InspectorPullRequestState.unavailable
    private var detail: PullRequestDetail?
    private var generation = 0
    private var isVisibleInInspector = false
    private var section = Section.description
    private var wrappingLabels = [NSTextField]()
    private static let headerHeight: CGFloat = 84
    private static let maxDescriptionCharacters = 20_000

    override var isFlipped: Bool { true }

    var focusView: NSView { segments }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Workspace.Inspector.PR.A11y", defaultValue: "Pull request", comment: "Accessibility label of the inspector's pull request pane"))

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = WorkspaceColor.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        metaLabel.font = .systemFont(ofSize: 11.5)
        metaLabel.textColor = WorkspaceColor.textSecondary
        metaLabel.lineBreakMode = .byTruncatingMiddle

        webButton.isBordered = false
        webButton.image = workspaceSymbolImage(.globe, pointSize: 12, weight: .regular)
        webButton.imagePosition = .imageOnly
        webButton.contentTintColor = WorkspaceColor.textSecondary
        webButton.toolTip = String(localized: "Workspace.PRDetail.OpenOnGitHub", defaultValue: "Open on GitHub", comment: "Opens the item in the browser")
        webButton.setAccessibilityLabel(webButton.toolTip)
        webButton.target = self
        webButton.action = #selector(openOnGitHub)
        refreshButton.isBordered = false
        refreshButton.image = workspaceSymbolImage(.arrowClockwise, pointSize: 12, weight: .regular)
        refreshButton.imagePosition = .imageOnly
        refreshButton.contentTintColor = WorkspaceColor.textSecondary
        refreshButton.toolTip = String(localized: "Workspace.Inspector.PR.Refresh", defaultValue: "Refresh", comment: "Tooltip of the refresh button in the inspector's pull request tab")
        refreshButton.setAccessibilityLabel(refreshButton.toolTip)
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)

        segments.segmentCount = Section.allCases.count
        segments.trackingMode = .selectOne
        segments.segmentStyle = .rounded
        segments.controlSize = .small
        segments.target = self
        segments.action = #selector(segmentChanged)
        updateSegmentLabels()
        segments.selectedSegment = section.rawValue

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -14)
        ])
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor).isActive = true
        document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor).isActive = true
        document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor).isActive = true

        separator.wantsLayer = true
        [scrollView, message, titleLabel, metaLabel, webButton, refreshButton, segments, separator].forEach(addSubview)
        applyState()
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) has not been implemented")
    }

    // MARK: State

    func setState(_ newState: InspectorPullRequestState) {
        guard newState != state else { return }
        state = newState
        generation += 1
        detail = nil
        applyState()
        loadIfNeeded()
    }

    func setVisibleInInspector(_ visible: Bool) {
        guard visible != isVisibleInInspector else { return }
        isVisibleInInspector = visible
        loadIfNeeded()
    }

    private var foundTarget: (repo: String, number: Int)? {
        if case .found(let repo, let number) = state { return (repo, number) }
        return nil
    }

    private func loadIfNeeded() {
        guard isVisibleInInspector, let target = foundTarget else { return }
        let token = generation
        GitHubClient.shared.pullRequestDetail(repo: target.repo, number: target.number) { [weak self] result in
            guard let self, token == self.generation else { return }
            switch result {
            case .success(let detail):
                self.detail = detail
                self.applyState()
            case .failure(let error):
                guard self.detail == nil else { return }
                self.showError(error)
            }
        }
    }

    private func showError(_ error: GitHubError) {
        let info = WorkspaceSetupMessage.content(for: error)
        message.text = info.heading + "\n" + info.body
        message.isHidden = false
        scrollView.isHidden = true
        setHeaderVisible(false)
    }

    private func setHeaderVisible(_ visible: Bool) {
        [titleLabel, metaLabel, webButton, segments, separator].forEach { $0.isHidden = !visible }
        refreshButton.isHidden = foundTarget == nil
    }

    private func applyState() {
        switch state {
        case .unavailable:
            showMessage(String(localized: "Workspace.Inspector.PR.Unavailable", defaultValue: "Open a session in a GitHub repository to see its pull request.", comment: "Shown in the inspector's pull request tab when the session has no GitHub repository or branch"))
        case .searching:
            showMessage(String(localized: "Workspace.Inspector.PR.Searching", defaultValue: "Looking for this branch’s pull request…", comment: "Shown in the inspector's pull request tab while the pull request for the branch is looked up"))
        case .none:
            showMessage(String(localized: "Workspace.Inspector.PR.None", defaultValue: "This branch has no pull request yet.", comment: "Shown in the inspector's pull request tab when the branch has no pull request"))
        case .found:
            guard let detail else {
                showMessage(String(localized: "Workspace.Inspector.PR.Loading", defaultValue: "Loading pull request…", comment: "Shown in the inspector's pull request tab while the pull request loads"))
                return
            }
            message.isHidden = true
            scrollView.isHidden = false
            setHeaderVisible(true)
            titleLabel.stringValue = "#\(detail.number) \(detail.title)"
            titleLabel.toolTip = titleLabel.stringValue
            metaLabel.stringValue = "\(detail.headRefName) → \(detail.baseRefName) · \(Self.stateText(detail))"
            metaLabel.toolTip = metaLabel.stringValue
            updateSegmentLabels()
            rebuild()
        }
    }

    private func showMessage(_ text: String) {
        message.text = text
        message.isHidden = false
        scrollView.isHidden = true
        setHeaderVisible(false)
    }

    private static func stateText(_ detail: PullRequestDetail) -> String {
        switch detail.state.uppercased() {
        case "MERGED": return String(localized: "Workspace.Inspector.PR.State.Merged", defaultValue: "Merged", comment: "State of a pull request")
        case "CLOSED": return String(localized: "Workspace.Inspector.PR.State.Closed", defaultValue: "Closed", comment: "State of a pull request")
        default:
            return detail.isDraft
                ? String(localized: "Workspace.Inspector.PR.State.Draft", defaultValue: "Draft", comment: "State of a pull request")
                : String(localized: "Workspace.Inspector.PR.State.Open", defaultValue: "Open", comment: "State of a pull request")
        }
    }

    // MARK: Segments

    private func updateSegmentLabels() {
        let files = detail?.files.count
        let titles = [
            String(localized: "Workspace.Inspector.PR.Tab.Description", defaultValue: "Description", comment: "PR sub-tab"),
            files.map { String(localized: "Workspace.Inspector.PR.Tab.FilesCount", defaultValue: "Files (\($0))", comment: "PR sub-tab with the number of changed files") }
                ?? String(localized: "Workspace.Inspector.PR.Tab.Files", defaultValue: "Files", comment: "PR sub-tab"),
            String(localized: "Workspace.Inspector.PR.Tab.Reviews", defaultValue: "Reviews", comment: "PR sub-tab"),
            String(localized: "Workspace.Inspector.PR.Tab.Checks", defaultValue: "Checks", comment: "PR sub-tab")
        ]
        for (index, title) in titles.enumerated() {
            segments.setLabel(title, forSegment: index)
        }
        segments.setAccessibilityLabel(String(localized: "Workspace.Inspector.PR.Sections.A11y", defaultValue: "Pull request sections", comment: "Accessibility label of the pull request sub-tabs"))
    }

    @objc private func segmentChanged() {
        guard let chosen = Section(rawValue: segments.selectedSegment) else { return }
        section = chosen
        rebuild()
    }

    // MARK: Content

    private func rebuild() {
        guard let detail else { return }
        wrappingLabels = []
        for view in content.arrangedSubviews {
            content.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        switch section {
        case .description: buildDescription(detail)
        case .files: buildFiles(detail)
        case .reviews: buildReviews(detail)
        case .checks: buildChecks(detail)
        }
        needsLayout = true
    }

    private func buildDescription(_ detail: PullRequestDetail) {
        let trimmed = detail.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            add(label(String(localized: "Workspace.PRDetail.Empty.Description", defaultValue: "No description provided.", comment: "Shown when a pull request has no description"), color: WorkspaceColor.textSecondary))
            return
        }
        let text = PullRequestDetailPage.stripHTML(String(trimmed.prefix(Self.maxDescriptionCharacters)))
        let field = label("", wraps: true)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: options) {
            let mutable = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
            let range = NSRange(location: 0, length: mutable.length)
            mutable.addAttribute(.font, value: NSFont.systemFont(ofSize: 12.5), range: range)
            mutable.addAttribute(.foregroundColor, value: WorkspaceColor.textPrimary, range: range)
            field.attributedStringValue = mutable
        } else {
            field.stringValue = text
        }
        add(field)
        if trimmed.count > Self.maxDescriptionCharacters {
            add(label(String(localized: "Workspace.PRDetail.Truncated", defaultValue: "This description is long, so it’s cut here. Read the rest on GitHub.", comment: "Shown under a pull request description that was shortened"), color: WorkspaceColor.textSecondary, wraps: true))
        }
    }

    private func buildFiles(_ detail: PullRequestDetail) {
        guard !detail.files.isEmpty else {
            add(label(String(localized: "Workspace.Inspector.PR.Files.Empty", defaultValue: "This pull request changes no files.", comment: "Shown in the inspector's pull request Files sub-tab when nothing changed"), color: WorkspaceColor.textSecondary))
            return
        }
        for file in detail.files {
            let path = label(file.path, mono: true)
            path.lineBreakMode = .byTruncatingMiddle
            path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let counts = label("+\(file.additions) −\(file.deletions)", color: WorkspaceColor.textSecondary, mono: true)
            counts.setContentHuggingPriority(.required, for: .horizontal)
            counts.setContentCompressionResistancePriority(.required, for: .horizontal)
            let row = NSStackView(views: [path, counts])
            row.orientation = .horizontal
            row.spacing = 8
            row.distribution = .fill
            add(row)
            row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
    }

    private func buildReviews(_ detail: PullRequestDetail) {
        guard !detail.reviews.isEmpty else {
            add(label(String(localized: "Workspace.PRDetail.Empty.Reviews", defaultValue: "No reviews yet.", comment: "Shown when a pull request has no reviews"), color: WorkspaceColor.textSecondary))
            return
        }
        for review in detail.reviews {
            add(label("\(review.author?.login ?? "") · \(Self.reviewText(review.state))", wraps: true))
        }
    }

    private func buildChecks(_ detail: PullRequestDetail) {
        guard !detail.statusCheckRollup.isEmpty else {
            add(label(String(localized: "Workspace.PRDetail.Empty.Checks", defaultValue: "No checks have run.", comment: "Shown when a pull request has no checks"), color: WorkspaceColor.textSecondary))
            return
        }
        for check in detail.statusCheckRollup {
            let symbol: SFSymbol
            let tint: NSColor
            switch check.outcome {
            case .passing: (symbol, tint) = (.checkmarkCircleFill, WorkspaceColor.success)
            case .failing: (symbol, tint) = (.xmarkCircleFill, WorkspaceColor.danger)
            case .running: (symbol, tint) = (.clock, WorkspaceColor.warning)
            case .neutral: (symbol, tint) = (.circleDashed, WorkspaceColor.textSecondary)
            }
            let button = LinkRowButton(title: check.displayName, target: self, action: #selector(checkTapped(_:)))
            button.isBordered = false
            button.alignment = .left
            button.font = .systemFont(ofSize: 12.5)
            button.image = workspaceSymbolImage(symbol, pointSize: 13)
            button.imagePosition = .imageLeading
            button.contentTintColor = tint
            button.url = check.url
            button.lineBreakMode = .byTruncatingTail
            button.attributedTitle = NSAttributedString(string: check.displayName, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: WorkspaceColor.textPrimary])
            button.setAccessibilityLabel("\(check.displayName), \(Self.outcomeText(check.outcome))")
            button.toolTip = check.url == nil ? nil : String(localized: "Workspace.Inspector.PR.Checks.Open", defaultValue: "Open this check on GitHub", comment: "Tooltip of a check row in the inspector's pull request tab")
            add(button)
        }
    }

    private static func outcomeText(_ outcome: PullRequestCheck.Outcome) -> String {
        switch outcome {
        case .passing: return String(localized: "Workspace.Inspector.PR.Check.Passing", defaultValue: "passing", comment: "VoiceOver state of a check")
        case .failing: return String(localized: "Workspace.Inspector.PR.Check.Failing", defaultValue: "failing", comment: "VoiceOver state of a check")
        case .running: return String(localized: "Workspace.Inspector.PR.Check.Running", defaultValue: "running", comment: "VoiceOver state of a check")
        case .neutral: return String(localized: "Workspace.Inspector.PR.Check.Neutral", defaultValue: "skipped", comment: "VoiceOver state of a check")
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

    private func label(_ text: String, color: NSColor = WorkspaceColor.textPrimary, wraps: Bool = false, mono: Bool = false) -> NSTextField {
        let field = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        field.font = mono ? .monospacedSystemFont(ofSize: 11.5, weight: .regular) : .systemFont(ofSize: 12.5)
        field.textColor = color
        field.isSelectable = true
        if wraps {
            wrappingLabels.append(field)
            field.preferredMaxLayoutWidth = max(100, bounds.width - 30)
        }
        return field
    }

    // MARK: Actions

    @objc private func checkTapped(_ sender: LinkRowButton) {
        if let url = sender.url {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openOnGitHub() {
        if let url = detail.flatMap({ URL(string: $0.url) }) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func refreshTapped() {
        generation += 1
        loadIfNeeded()
    }

    // MARK: Layout

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            separator.layer?.backgroundColor = WorkspaceColor.separator.cgColor
        }
        let width = bounds.width
        titleLabel.frame = NSRect(x: 14, y: 10, width: max(0, width - 28 - 56), height: 18)
        metaLabel.frame = NSRect(x: 14, y: 30, width: max(0, width - 28), height: 16)
        refreshButton.frame = NSRect(x: width - 42, y: 6, width: 24, height: 24)
        webButton.frame = NSRect(x: width - 70, y: 6, width: 24, height: 24)
        segments.frame = NSRect(x: 12, y: 52, width: max(0, width - 24), height: 22)
        separator.frame = NSRect(x: 0, y: Self.headerHeight - 1, width: width, height: 1)
        let body = NSRect(x: 0, y: Self.headerHeight, width: width, height: max(0, bounds.height - Self.headerHeight))
        scrollView.frame = body
        message.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        for field in wrappingLabels {
            field.preferredMaxLayoutWidth = max(100, width - 30)
            field.invalidateIntrinsicContentSize()
        }
    }
}
