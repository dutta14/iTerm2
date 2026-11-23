//
//  WorkspaceController.swift
//  iTerm2SharedARC
//
//  Owns the workspace chrome of one terminal window: the sidebar and header views, their
//  visibility, and the bridge between sidebar rows and terminal sessions. The frames come from
//  iTermLayoutCalculator; iTermRootTerminalView applies them.
//

import AppKit

@objc(iTermWorkspaceController)
final class WorkspaceController: NSObject {
    @objc let sidebarView = WorkspaceSidebarView(frame: .zero)
    @objc let headerView = WorkspaceHeaderView(frame: .zero)
    private weak var rootView: iTermRootTerminalView?
    private var syncTimer: Timer?
    private var keyMonitor: Any?
    private var repoCache = [String: RepoInfo?]()
    private var pendingResolutions = Set<String>()
    private var activeNav: WorkspaceNavItem?
    private var host: WorkspaceFullWindowHost?
    private let store = WorkspaceSessionStore.shared

    @objc static var isEnabled: Bool {
        return WorkspaceSettings.isEnabled
    }

    @objc(initWithRootView:)
    init(rootView: iTermRootTerminalView) {
        self.rootView = rootView
        super.init()
        sidebarView.delegate = self
        headerView.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        headerView.onBack = { [weak self] in self?.closeFullWindowView() }
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(storeDidChange),
                                               name: WorkspaceSessionStore.didChangeNotification,
                                               object: store)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(settingsDidChange),
                                               name: WorkspaceSettings.didChangeNotification,
                                               object: nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.window != nil,
                  event.window === self.rootView?.window else {
                return event
            }
            return self.handle(keyEvent: event) ? nil : event
        }
    }

    deinit {
        syncTimer?.invalidate()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        NotificationCenter.default.removeObserver(self)
    }

    private func handle(keyEvent event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers
        if flags == .command, key == "b" {
            toggleSidebar()
            return true
        }
        if flags == [.command, .control] {
            switch key {
            case "0": closeFullWindowView(); return true
            case "1": show(.pullRequests); return true
            case "2": show(.issues); return true
            case "3": show(.automations); return true
            default: break
            }
        }
        if flags == .command, let host, host.destination != nil {
            if key == "[" { host.goBack(); return true }
            if key == "]" { host.goForward(); return true }
        }
        return false
    }

    // MARK: - Layout contract

    /// Width the sidebar occupies for a window of the given width. Zero when collapsed.
    @objc(sidebarLayoutWidthForWindowWidth:)
    func sidebarLayoutWidth(forWindowWidth windowWidth: CGFloat) -> CGFloat {
        guard WorkspaceSettings.sidebarVisible,
              windowWidth >= WorkspaceSettings.collapseSidebarBelowWindowWidth else {
            return 0
        }
        return iTermLayoutCalculator.workspaceSidebarWidth(forProposed: WorkspaceSettings.sidebarWidth,
                                                           windowWidth: windowWidth)
    }

    @objc var headerLayoutHeight: CGFloat {
        return WorkspaceSettings.headerHeight
    }

    /// Called from iTermRootTerminalView after every layout pass.
    @objc(applyOutputs:)
    func apply(outputs: iTermLayoutOutputs) {
        guard let rootView else { return }
        for view in [sidebarView, headerView] where view.superview !== rootView {
            rootView.addSubview(view, positioned: .above, relativeTo: nil)
        }
        sidebarView.frame = outputs.workspaceSidebarFrame
        sidebarView.isHidden = outputs.workspaceSidebarFrame.isEmpty
        headerView.frame = outputs.workspaceHeaderFrame
        headerView.isHidden = outputs.workspaceHeaderFrame.isEmpty
        sidebarView.setToggleTooltip(visible: !sidebarView.isHidden)
        layoutHost(in: rootView, outputs: outputs)
        rootView.window?.appearance = WorkspaceSettings.appearanceMode.appearance
        startSyncingIfNeeded()
        refresh()
    }

    // MARK: - Syncing live sessions

    private func startSyncingIfNeeded() {
        guard syncTimer == nil else { return }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        syncTimer = timer
        store.importCopilotSessionsInBackground()
    }

    private func layoutHost(in rootView: iTermRootTerminalView, outputs: iTermLayoutOutputs) {
        guard let host, host.superview === rootView else { return }
        let x = outputs.workspaceSidebarFrame.isEmpty ? 0 : outputs.workspaceSidebarFrame.maxX
        let top = outputs.workspaceHeaderFrame.isEmpty ? rootView.bounds.height : outputs.workspaceHeaderFrame.minY
        host.frame = NSRect(x: x, y: 0, width: max(0, rootView.bounds.width - x), height: max(0, top))
    }

    private var terminal: PseudoTerminal? {
        return rootView?.delegate as? PseudoTerminal
    }

    private func liveRecords() -> [WorkspaceSessionRecord] {
        guard let terminal else { return [] }
        var records = [WorkspaceSessionRecord]()
        for session in terminal.allSessions() {
            let cwd = session.currentLocalWorkingDirectory
            let info = cwd.flatMap { resolveRepo(directory: $0) }
            records.append(WorkspaceSessionRecord(id: "live-" + session.guid,
                                                  copilotSessionId: nil,
                                                  imported: false,
                                                  repo: info?.repo,
                                                  repoSource: info == nil ? .none : .resolved,
                                                  cwd: cwd,
                                                  branch: info?.branch,
                                                  title: session.name,
                                                  status: .running,
                                                  updatedAt: Date(),
                                                  prNumber: nil,
                                                  issueNumber: nil,
                                                  terminalGuid: session.guid))
        }
        return records
    }

    // Resolution shells out to git, so it runs off the main thread and the answer shows up on the next refresh.
    private func resolveRepo(directory: String) -> RepoInfo? {
        if let cached = repoCache[directory] {
            return cached
        }
        guard pendingResolutions.insert(directory).inserted else { return nil }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let info = RepoResolver.resolve(directory: directory)
            DispatchQueue.main.async {
                self?.repoCache[directory] = .some(info)
                self?.pendingResolutions.remove(directory)
                self?.refresh()
            }
        }
        return nil
    }

    @objc private func storeDidChange() {
        reloadSidebar()
    }

    @objc private func settingsDidChange() {
        rootView?.window?.appearance = WorkspaceSettings.appearanceMode.appearance
    }

    @objc func refresh() {
        store.setLiveRecords(liveRecords())
        reloadSidebar()
        updateHeader()
    }

    private func reloadSidebar() {
        let selected = terminal?.currentSession().map { "live-" + $0.guid }
        sidebarView.update(groups: store.groups(),
                           selectedRecordId: activeNav == nil ? selected : nil,
                           activeNav: activeNav)
    }

    private func updateHeader() {
        let session = terminal?.currentSession()
        let record = session.flatMap { s in store.liveRecords.first { $0.terminalGuid == s.guid } }
        let collapsed = sidebarView.isHidden
        let title = record?.title ?? session?.name ?? ""
        headerView.update(content: WorkspaceHeaderView.Content(repo: record?.repo,
                                                               branch: record?.branch,
                                                               title: title,
                                                               viewName: host?.viewName),
                          sidebarCollapsed: collapsed)
    }

    // MARK: - Actions

    @objc func toggleSidebar() {
        WorkspaceSettings.sidebarVisible.toggle()
        rootView?.layoutSubviews()
        refresh()
    }

    private func launchSession(directory: String?,
                               command: String?,
                               title: String? = nil,
                               prefill: String? = nil) {
        guard let terminal else { return }
        guard let base = ProfileModel.sharedInstance().defaultProfile() else { return }
        closeFullWindowView()
        let profile = NSMutableDictionary(dictionary: base)
        if let directory, FileManager.default.fileExists(atPath: directory) {
            profile[KEY_CUSTOM_DIRECTORY] = kProfilePreferenceInitialDirectoryCustomValue
            profile[KEY_WORKING_DIRECTORY] = directory
        }
        if let title {
            profile[KEY_NAME] = title
        }
        iTermSessionLauncher.launchBookmark(profile as? [AnyHashable: Any],
                                            in: terminal,
                                            respectTabbingMode: false) { [weak self] session in
            if let command {
                session.writeTask(command + "\n")
            }
            if let prefill {
                self?.prefill(prompt: prefill, in: session)
            }
        }
    }

    /// Types the prompt without Return once Copilot CLI has had time to start. The prompt is also
    /// on the pasteboard so it survives a slow start.
    private func prefill(prompt: String, in session: PTYSession) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak session] in
            guard let session, self?.terminal?.allSessions().contains(where: { $0 === session }) == true else { return }
            session.writeTask(prompt)
        }
    }

    // MARK: - Full-window views

    private func show(_ destination: WorkspaceDestination) {
        guard let rootView else { return }
        let host: WorkspaceFullWindowHost
        if let existing = self.host {
            host = existing
        } else {
            host = WorkspaceFullWindowHost(frame: .zero)
            host.pageDelegate = self
            host.onClose = { [weak self] in self?.closeFullWindowView() }
            host.onDestinationChange = { [weak self] in
                guard let self else { return }
                self.activeNav = self.host?.destination?.navItem
                self.refresh()
            }
            self.host = host
        }
        if host.superview !== rootView {
            rootView.addSubview(host, positioned: .below, relativeTo: sidebarView)
        }
        rootView.layoutSubviews()
        host.show(destination)
    }

    private func closeFullWindowView() {
        guard let host, host.superview != nil else { return }
        host.reset()
        host.removeFromSuperview()
        activeNav = nil
        refresh()
        terminal?.currentSession()?.takeFocus()
    }

    var knownRepos: [String] {
        var repos = Set<String>()
        for record in store.visibleRecords + store.liveRecords {
            if let repo = record.repo, GitHubClient.isValid(repo: repo) {
                repos.insert(repo)
            }
        }
        return Array(repos.sorted().prefix(12))
    }

    /// AC-099: the folder of an existing session in that repo, else ask.
    private func resolveDirectory(forRepo repo: String) -> String? {
        if let known = directory(forRepo: repo) {
            return known
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Workspace.Folder.Choose", defaultValue: "Choose folder…", comment: "Button in the panel that asks for the local clone of a repository")
        panel.message = String(localized: "Workspace.Folder.Message", defaultValue: "Choose your local clone of \(repo).", comment: "Message in the panel that asks for the local clone of a repository. The placeholder is owner/name.")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    private func warn(heading: String, message: String) {
        let warning = iTermWarning()
        warning.heading = heading
        warning.title = message
        warning.actionLabels = [iTermLocalizedOK()]
        warning.warningType = .kiTermWarningTypePersistent
        warning.window = rootView?.window
        _ = warning.runModal()
    }

    private func directory(forRepo repo: String?) -> String? {
        guard let repo else { return nil }
        let match = store.visibleRecords.first { $0.repo == repo && $0.cwd != nil }
        guard let cwd = match?.cwd else { return nil }
        return repoCache[cwd]??.root ?? cwd
    }
}

extension WorkspaceController: WorkspaceSidebarDelegate {
    func sidebarDidRequestToggle(_ sidebar: WorkspaceSidebarView) {
        toggleSidebar()
    }

    func sidebarDidRequestSearch(_ sidebar: WorkspaceSidebarView) {
        NSApp.sendAction(NSSelectorFromString("openQuickly:"), to: nil, from: self)
    }

    func sidebar(_ sidebar: WorkspaceSidebarView, didSelectNav item: WorkspaceNavItem) {
        switch item {
        case .newSession:
            closeFullWindowView()
            launchSession(directory: nil, command: "copilot")
        case .pullRequests:
            show(.pullRequests)
        case .issues:
            show(.issues)
        case .automations:
            show(.automations)
        }
    }

    func sidebar(_ sidebar: WorkspaceSidebarView, didSelectSession record: WorkspaceSessionRecord) {
        closeFullWindowView()
        if let guid = record.terminalGuid,
           let terminal,
           let session = terminal.allSessions().first(where: { $0.guid == guid }),
           let tab = terminal.tabs().first(where: { $0.sessions().contains { $0 === session } }) {
            terminal.tabView().selectTabViewItem(tab.tabViewItem)
            refresh()
            return
        }
        guard let id = record.copilotSessionId, Self.isUUID(id) else { return }
        launchSession(directory: record.cwd, command: "copilot --resume " + id)
    }

    func sidebar(_ sidebar: WorkspaceSidebarView, didRequestNewSessionInRepo repo: String?) {
        launchSession(directory: directory(forRepo: repo), command: "copilot")
    }

    func sidebarDidRequestSettings(_ sidebar: WorkspaceSidebarView) {
        NSApp.sendAction(NSSelectorFromString("showPrefWindow:"), to: nil, from: self)
    }

    private static func isUUID(_ text: String) -> Bool {
        return UUID(uuidString: text) != nil
    }
}

extension WorkspaceController: WorkspacePageDelegate {
    func workspacePage(showPullRequest repo: String, number: Int) {
        show(.pullRequestDetail(repo: repo, number: number))
    }

    func workspacePageKnownRepos() -> [String] {
        return knownRepos
    }

    func workspacePage(showLogTitled title: String, text: String) {
        host?.presentLog(title: title, text: text)
    }

    func workspacePage(copyToPasteboard text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func workspacePage(startSessionOnPullRequest repo: String, number: Int, title: String) {
        guard let directory = resolveDirectory(forRepo: repo) else { return }
        let sessionTitle = "PR #\(number): \(title)"
        GitHubClient.shared.checkoutPullRequest(number: number, repo: repo, directory: directory) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.launchSession(directory: directory, command: "copilot", title: sessionTitle)
            case .failure:
                let warning = iTermWarning()
                warning.heading = String(localized: "Workspace.PRDetail.CheckoutFailed.Title", defaultValue: "Couldn’t check out the branch", comment: "Title of the alert shown when checking out a pull request branch fails")
                warning.title = String(localized: "Workspace.PRDetail.CheckoutFailed", defaultValue: "Couldn’t check out the branch for PR #\(number). You can start the session without switching branches.", comment: "Body of the alert shown when checking out a pull request branch fails. The placeholder is the pull request number.")
                let start = String(localized: "Workspace.PRDetail.StartWithoutSwitching", defaultValue: "Start without switching branch", comment: "Button that starts the session anyway")
                warning.actionLabels = [start, iTermLocalizedCancel()]
                warning.cancelLabel = iTermLocalizedCancel()
                warning.warningType = .kiTermWarningTypePersistent
                warning.window = self.rootView?.window
                if warning.runModal() == .kiTermWarningSelection0 {
                    self.launchSession(directory: directory, command: "copilot", title: sessionTitle)
                }
            }
        }
    }

    func workspacePage(startSessionOnIssue repo: String, number: Int, title: String) {
        guard let directory = resolveDirectory(forRepo: repo) else { return }
        let branch = GitHubClient.issueBranchName(number: number, title: title)
        GitHubClient.shared.branchState(name: branch, directory: directory) { [weak self] state in
            self?.confirmIssueSession(repo: repo, number: number, title: title, directory: directory, branch: branch, state: state)
        }
    }

    private func confirmIssueSession(repo: String,
                                     number: Int,
                                     title: String,
                                     directory: String,
                                     branch: String,
                                     state: GitHubClient.BranchState) {
        let folder = (directory as NSString).abbreviatingWithTildeInPath
        var message = String(localized: "Workspace.Issues.Sheet.Message", defaultValue: "Copilot CLI starts in \(folder) with a prompt to fix this issue. Pick the branch it should work on.", comment: "Body of the sheet that starts a session on an issue. The placeholder is a folder path.")
        if state.exists {
            message += "\n" + String(localized: "Workspace.Issues.Sheet.BranchExists", defaultValue: "Branch \(branch) already exists in this repo.", comment: "Shown when the suggested branch name is taken. The placeholder is a branch name.")
        } else if state.dirty {
            message += "\n" + String(localized: "Workspace.Issues.Sheet.DirtyNote", defaultValue: "You have uncommitted changes. They carry over to the new branch.", comment: "Shown when the working tree has uncommitted changes")
        }
        let field = NSTextField(string: branch)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        field.setAccessibilityLabel(String(localized: "Workspace.Issues.Sheet.BranchLabel", defaultValue: "New branch name", comment: "Label of the field holding the new branch name"))
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        accessory.addSubview(field)

        let primary = state.exists
            ? String(localized: "Workspace.Issues.Sheet.UseExisting", defaultValue: "Use existing branch", comment: "Button that switches to the branch that already exists")
            : String(localized: "Workspace.Issues.Sheet.CreateBranch", defaultValue: "Create branch and start", comment: "Button that creates the branch and starts the session")
        let current = String(localized: "Workspace.Issues.Sheet.StartCurrent", defaultValue: "Start on current branch", comment: "Button that starts the session without switching branches")
        let warning = iTermWarning()
        warning.heading = String(localized: "Workspace.Issues.Sheet.Title", defaultValue: "Start a session on issue #\(number)", comment: "Title of the sheet that starts a session on an issue. The placeholder is the issue number.")
        warning.title = message
        warning.accessory = field.superview
        warning.actionLabels = [primary, current, iTermLocalizedCancel()]
        warning.cancelLabel = iTermLocalizedCancel()
        warning.warningType = .kiTermWarningTypePersistent
        warning.window = rootView?.window
        let selection = warning.runModal()
        let sessionTitle = "Issue #\(number): \(title)"
        let prompt = GitHubClient.issuePrompt(number: number, repo: repo, title: title)
        let chosen = field.stringValue.trimmingCharacters(in: .whitespaces)
        switch selection {
        case .kiTermWarningSelection0:
            guard !chosen.isEmpty, !chosen.hasPrefix("-"), !chosen.contains(" ") else { return }
            let useExisting = state.exists && chosen == branch
            GitHubClient.shared.switchToBranch(name: chosen, create: !useExisting, directory: directory) { [weak self] result in
                switch result {
                case .success:
                    self?.launchSession(directory: directory, command: "copilot", title: sessionTitle, prefill: prompt)
                case .failure(let error):
                    var detail = chosen
                    if case .failed(let text) = error, !text.isEmpty {
                        detail += "\n" + text
                    }
                    self?.warn(heading: String(localized: "Workspace.Issues.Sheet.CreateFailed", defaultValue: "Couldn’t create branch \(detail).", comment: "Shown when creating the branch fails. The placeholder is the branch name and the reason."),
                               message: "")
                }
            }
        case .kiTermWarningSelection1:
            launchSession(directory: directory, command: "copilot", title: sessionTitle, prefill: prompt)
        default:
            break
        }
    }
}
