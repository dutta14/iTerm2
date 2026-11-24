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
    /// Copilot session IDs for terminals started with `copilot --resume`, keyed by terminal GUID.
    /// Lets the live row replace the stored row instead of appearing next to it.
    private var resumedCopilotSessionIds = [String: String]()
    private lazy var inspectorView: WorkspaceInspectorView = makeInspector()
    private let minimapView = WorkspaceMinimapView(frame: .zero)
    private var inspectorExpanded = false
    private var lastInspectorContext: String?
    private var branchPullRequests = [String: (date: Date, match: PullRequestBranchMatch?, failed: Bool)]()
    private var pendingPullRequestLookups = Set<String>()
    private static let pullRequestCacheSeconds: TimeInterval = 60
    private var minimapTimer: Timer?
    private var minimapPrompts = [MinimapPrompt]()
    private var minimapSessionGuid: String?
    private static let controllers = NSHashTable<WorkspaceController>.weakObjects()

    /// The controller of the key window, for menu commands.
    static var current: WorkspaceController? {
        return controllers.allObjects.first { $0.rootView?.window === NSApp.keyWindow }
    }

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
        headerView.onToggleInspector = { [weak self] in self?.toggleInspector() }
        headerView.onViewPR = { [weak self] in self?.viewPullRequest() }
        minimapView.onJump = { [weak self] index in self?.jumpToPrompt(at: index) }
        minimapView.isHidden = true
        Self.controllers.add(self)
        WorkspaceMenu.installIfNeeded()
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
        minimapTimer?.invalidate()
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
        if flags == [.option, .command], key == "\\" {
            toggleInspector()
            return true
        }
        if flags == .command, key == "\\" {
            showInspectorTab(.changes)
            return true
        }
        if flags == [.command, .shift], key == "|" || key == "\\" {
            showInspectorTab(.pullRequest)
            return true
        }
        if flags == .control, key == "`" {
            toggleTerminalTab()
            return true
        }
        if flags == [.command, .control], key == "i" {
            focusInspector()
            return true
        }
        let arrowFlags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if arrowFlags == .option, event.keyCode == 125 || event.keyCode == 126, minimapView.isHidden == false {
            stepPrompt(forward: event.keyCode == 125)
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

    /// Width the inspector occupies. It yields before the terminal drops under its minimum width,
    /// and is absent while a full-window view is up.
    @objc(inspectorLayoutWidthForWindowWidth:sidebarWidth:)
    func inspectorLayoutWidth(forWindowWidth windowWidth: CGFloat, sidebarWidth: CGFloat) -> CGFloat {
        guard WorkspaceSettings.inspectorVisible,
              host?.superview == nil,
              windowWidth >= WorkspaceSettings.collapseInspectorBelowWindowWidth else {
            return 0
        }
        let proposed = inspectorExpanded ? windowWidth * 0.5 : WorkspaceSettings.inspectorWidth
        let clamped = iTermLayoutCalculator.workspaceInspectorWidth(forProposed: proposed, windowWidth: windowWidth)
        let available = windowWidth - sidebarWidth - WorkspaceSettings.minimumTerminalColumnWidth
        return available >= clamped ? clamped : (available >= 280 ? available : 0)
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
        layoutInspector(in: rootView, outputs: outputs)
        layoutHost(in: rootView, outputs: outputs)
        rootView.window?.appearance = WorkspaceSettings.appearanceMode.appearance
        startSyncingIfNeeded()
        refresh()
    }

    // MARK: - Syncing live sessions

    private func startSyncingIfNeeded() {
        guard syncTimer == nil else { return }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.store.importCopilotSessionsInBackground()
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        syncTimer = timer
        store.importCopilotSessionsInBackground()
    }

    private func makeInspector() -> WorkspaceInspectorView {
        let view = WorkspaceInspectorView(frame: .zero)
        view.isHidden = true
        view.onResize = { [weak self] width in
            guard let self, let rootView = self.rootView else { return }
            self.inspectorExpanded = false
            self.inspectorView.setExpanded(false)
            WorkspaceSettings.inspectorWidth = width
            rootView.layoutSubviews()
        }
        view.onToggleExpand = { [weak self] in
            guard let self, let rootView = self.rootView else { return }
            self.inspectorExpanded.toggle()
            self.inspectorView.setExpanded(self.inspectorExpanded)
            rootView.layoutSubviews()
        }
        return view
    }

    private func layoutInspector(in rootView: iTermRootTerminalView, outputs: iTermLayoutOutputs) {
        let inspector = inspectorView
        if inspector.superview !== rootView {
            rootView.addSubview(inspector, positioned: .above, relativeTo: nil)
        }
        if minimapView.superview !== rootView {
            rootView.addSubview(minimapView, positioned: .above, relativeTo: nil)
        }
        inspector.frame = outputs.workspaceInspectorFrame
        inspector.isHidden = outputs.workspaceInspectorFrame.isEmpty
        if inspector.isHidden {
            inspectorExpanded = false
        }
        let tab = outputs.tabViewFrame
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: NSScroller.preferredScrollerStyle)
        minimapView.frame = NSRect(x: tab.maxX - MinimapModel.columnWidth - scroller,
                                   y: tab.minY,
                                   width: MinimapModel.columnWidth,
                                   height: tab.height)
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
            let copilotSessionId = resumedCopilotSessionIds[session.guid]
            // Copilot can change its working directory without moving the shell's, so trust its own record.
            let copilotCwd = copilotSessionId.flatMap { id in
                store.records.first { $0.copilotSessionId == id }?.cwd
            }
            let cwd = copilotCwd ?? session.currentLocalWorkingDirectory
            let info = cwd.flatMap { resolveRepo(directory: $0) }
            let prNumber = info.flatMap { pullRequestMatch(repo: $0.repo, branch: $0.branch)?.number }
            records.append(WorkspaceSessionRecord(id: "live-" + session.guid,
                                                  copilotSessionId: copilotSessionId,
                                                  imported: false,
                                                  repo: info?.repo,
                                                  repoSource: info == nil ? .none : .resolved,
                                                  cwd: cwd,
                                                  branch: info?.branch,
                                                  title: session.name,
                                                  status: .running,
                                                  updatedAt: Date(),
                                                  prNumber: prNumber,
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
        updateMinimap(recomputePrompts: false)
    }

    @objc func refresh() {
        store.setLiveRecords(liveRecords())
        reloadSidebar()
        updateHeader()
        updateInspectorContext()
        updateMinimap(recomputePrompts: true)
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
                                                               viewName: host?.viewName,
                                                               inspectorVisible: WorkspaceSettings.inspectorVisible,
                                                               inspectorAvailable: host?.superview == nil,
                                                               prNumber: record?.prNumber),
                          sidebarCollapsed: collapsed)
    }

    // MARK: - Actions

    @objc func toggleSidebar() {
        WorkspaceSettings.sidebarVisible.toggle()
        rootView?.layoutSubviews()
        refresh()
    }

    // MARK: - Inspector

    private func updateInspectorContext() {
        let session = terminal?.currentSession()
        let guids = Set(terminal?.allSessions().map { $0.guid } ?? [])
        let directory = session?.currentLocalWorkingDirectory
        let key = "\(session?.guid ?? "")|\(directory ?? "")"
        if key != lastInspectorContext {
            lastInspectorContext = key
            inspectorView.setContext(sessionGuid: session?.guid, directory: directory)
        }
        inspectorView.pruneTerminals(keeping: guids)
        inspectorView.setPullRequestState(pullRequestState(for: session))
    }

    private func pullRequestState(for session: PTYSession?) -> InspectorPullRequestState {
        guard let session,
              let record = store.liveRecords.first(where: { $0.terminalGuid == session.guid }),
              let repo = record.repo, GitHubClient.isValid(repo: repo),
              let branch = record.branch, !branch.isEmpty else {
            return .unavailable
        }
        let key = "\(repo)|\(branch)"
        if let cached = branchPullRequests[key] {
            if cached.failed { return .unavailable }
            return cached.match.map { .found(repo: repo, number: $0.number) } ?? .none
        }
        return .searching
    }

    /// Looks up the pull request for a branch at most once a minute. The answer shows up on the next refresh.
    private func pullRequestMatch(repo: String, branch: String?) -> PullRequestBranchMatch? {
        guard let branch, !branch.isEmpty, GitHubClient.isValid(repo: repo) else { return nil }
        let key = "\(repo)|\(branch)"
        let cached = branchPullRequests[key]
        let stale = cached.map { Date().timeIntervalSince($0.date) > Self.pullRequestCacheSeconds } ?? true
        if stale, pendingPullRequestLookups.insert(key).inserted {
            GitHubClient.shared.pullRequests(forBranch: branch, repo: repo) { [weak self] result in
                guard let self else { return }
                self.pendingPullRequestLookups.remove(key)
                switch result {
                case .success(let matches):
                    self.branchPullRequests[key] = (Date(), PullRequestBranchPicker.pick(from: matches), false)
                case .failure:
                    // Keep any earlier answer and retry after the cache window.
                    self.branchPullRequests[key] = (Date(), cached?.match, cached?.failed ?? true)
                }
                self.refresh()
            }
        }
        return cached?.match
    }

    private func viewPullRequest() {
        if host?.superview != nil { return }
        showInspectorTab(.pullRequest)
    }

    @objc func toggleInspector() {
        if host?.superview != nil { return }
        WorkspaceSettings.inspectorVisible.toggle()
        rootView?.layoutSubviews()
        refresh()
        if !WorkspaceSettings.inspectorVisible, inspectorView.terminalHasFocus {
            terminal?.currentSession()?.takeFocus()
        }
    }

    private func revealInspector() {
        guard host?.superview == nil else { return }
        if !WorkspaceSettings.inspectorVisible {
            WorkspaceSettings.inspectorVisible = true
        }
        rootView?.layoutSubviews()
        refresh()
    }

    func showInspectorTab(_ kind: InspectorTabKind) {
        revealInspector()
        inspectorView.activate(kind)
        inspectorView.focusActivePane()
    }

    private func toggleTerminalTab() {
        if WorkspaceSettings.inspectorVisible, inspectorView.activeKind == .terminal, inspectorView.terminalHasFocus {
            terminal?.currentSession()?.takeFocus()
        } else {
            showInspectorTab(.terminal)
        }
    }

    func focusInspectorFromMenu() { focusInspector() }

    private func focusInspector() {
        revealInspector()
        inspectorView.focusActivePane()
    }

    @objc func resetLayout() {
        let warning = iTermWarning()
        warning.heading = String(localized: "Workspace.Settings.ResetLayout.Heading", defaultValue: "Reset layout?", comment: "Heading of the confirmation for resetting the workspace layout")
        warning.title = String(localized: "Workspace.Settings.ResetLayout.Confirm", defaultValue: "The sidebar and inspector return to their default size and visibility.", comment: "Body of the confirmation for resetting the workspace layout")
        warning.actionLabels = [String(localized: "Workspace.Settings.ResetLayout.Action", defaultValue: "Reset", comment: "Confirm button for resetting the workspace layout"), iTermLocalizedCancel()]
        warning.warningType = .kiTermWarningTypePersistent
        warning.window = rootView?.window
        guard warning.runModal() == .kiTermWarningSelection0 else { return }
        WorkspaceSettings.resetLayout()
        inspectorExpanded = false
        inspectorView.setExpanded(false)
        rootView?.layoutSubviews()
        refresh()
    }

    // MARK: - Minimap

    private var minimapSession: PTYSession? {
        return terminal?.currentSession()
    }

    private func promptsForMinimap(in session: PTYSession) -> [MinimapPrompt] {
        var newestFirst = [(line: Int64, text: String, outputStart: Int64)]()
        session.screen.enumeratePromptsBackward { mark, stop in
            if mark.isPrompt, let command = mark.fullCommand, !command.isEmpty {
                newestFirst.append((mark.promptRange.start.y, command, mark.outputStart.y))
            }
            if newestFirst.count >= 2000 {
                stop.pointee = true
            }
        }
        let ordered = Array(newestFirst.reversed())
        return ordered.enumerated().map { index, entry in
            let end = index + 1 < ordered.count ? ordered[index + 1].line : entry.outputStart + 1
            return MinimapPrompt(id: "\(entry.line)", text: entry.text, absoluteLine: entry.line, isLong: end - entry.outputStart > 30)
        }
    }

    private func visibleBottomLine(of session: PTYSession) -> Int64? {
        guard let textView = session.textview else { return nil }
        let range = textView.rangeOfVisibleLines
        return Int64(textView.firstVisibleAbsoluteLineNumber) + Int64(max(0, range.length - 1))
    }

    private func updateMinimap(recomputePrompts: Bool) {
        guard let session = minimapSession, host?.superview == nil else {
            minimapView.isHidden = true
            return
        }
        if recomputePrompts || session.guid != minimapSessionGuid {
            minimapSessionGuid = session.guid
            minimapPrompts = promptsForMinimap(in: session)
        }
        let show = MinimapModel.shouldShow(promptCount: minimapPrompts.count, enabled: WorkspaceSettings.minimapEnabled)
        minimapView.isHidden = !show
        if show {
            let bottom = visibleBottomLine(of: session)
            let current = bottom.flatMap { MinimapModel.currentPromptIndex(prompts: minimapPrompts, visibleBottomAbsoluteLine: $0) }
            minimapView.update(prompts: minimapPrompts, currentIndex: current)
            startMinimapTimer()
        } else {
            minimapTimer?.invalidate()
            minimapTimer = nil
        }
    }

    private func startMinimapTimer() {
        guard minimapTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateMinimap(recomputePrompts: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        minimapTimer = timer
    }

    private func jumpToPrompt(at index: Int) {
        guard minimapPrompts.indices.contains(index), let session = minimapSession else { return }
        session.textview?.scroll(toAbsoluteOffset: minimapPrompts[index].absoluteLine, height: 1)
        updateMinimap(recomputePrompts: false)
    }

    private func stepPrompt(forward: Bool) {
        guard let session = minimapSession, let textView = session.textview else { return }
        let top = Int64(textView.firstVisibleAbsoluteLineNumber)
        let target = forward
            ? MinimapModel.nextIndex(prompts: minimapPrompts, visibleTopAbsoluteLine: top)
            : MinimapModel.previousIndex(prompts: minimapPrompts, visibleTopAbsoluteLine: top)
        if let target {
            jumpToPrompt(at: target)
        }
    }

    private func launchSession(directory: String?,
                               command: String?,
                               title: String? = nil,
                               prefill: String? = nil,
                               resumingCopilotSessionId: String? = nil) {
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
            if let resumingCopilotSessionId {
                self?.resumedCopilotSessionIds[session.guid] = resumingCopilotSessionId
            }
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
            promptForRepoAndLaunchSession()
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
        launchSession(directory: record.cwd,
                      command: "copilot --resume " + id,
                      title: record.title,
                      resumingCopilotSessionId: id)
    }

    func sidebar(_ sidebar: WorkspaceSidebarView, didRequestNewSessionInRepo repo: String?) {
        guard repo != nil else {
            promptForRepoAndLaunchSession()
            return
        }
        launchSession(directory: directory(forRepo: repo), command: "copilot")
    }

    /// Asks which repository a new session belongs to. Repos come from the sidebar's own groups.
    private func promptForRepoAndLaunchSession() {
        let menu = NSMenu()
        let header = NSMenuItem(title: String(localized: "Workspace.NewSession.Menu.Header",
                                              defaultValue: "Start a session in…",
                                              comment: "Heading of the menu that asks which repository a new session should start in."),
                                action: nil,
                                keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for group in store.groups() {
            guard let repo = group.repo, let directory = directory(forRepo: repo) else { continue }
            let item = NSMenuItem(title: repo, action: #selector(newSessionRepoChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = directory
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let folder = NSMenuItem(title: String(localized: "Workspace.NewSession.Menu.Folder",
                                              defaultValue: "Choose Folder…",
                                              comment: "Menu item that lets the user pick any folder to start a new session in."),
                                action: #selector(newSessionFolderChosen(_:)),
                                keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        let none = NSMenuItem(title: String(localized: "Workspace.NewSession.Menu.NoRepo",
                                            defaultValue: "No Repository",
                                            comment: "Menu item that starts a new session with no repository."),
                              action: #selector(newSessionRepoChosen(_:)),
                              keyEquivalent: "")
        none.target = self
        menu.addItem(none)
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: sidebarView)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    @objc private func newSessionRepoChosen(_ sender: NSMenuItem) {
        launchSession(directory: sender.representedObject as? String, command: "copilot")
    }

    @objc private func newSessionFolderChosen(_ sender: NSMenuItem) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        launchSession(directory: url.path, command: "copilot")
    }

    func sidebarDidRequestSettings(_ sidebar: WorkspaceSidebarView) {
        NSApp.sendAction(NSSelectorFromString("showPrefWindow:"), to: nil, from: self)
    }

    func sidebar(_ sidebar: WorkspaceSidebarView, didRequestRemoveSessions records: [WorkspaceSessionRecord], inRepo repo: String?) {
        guard !records.isEmpty else { return }
        if records.count > 1 {
            let warning = iTermWarning()
            let name = repo ?? String(localized: "Workspace.Sidebar.NoRepo.Label",
                                      defaultValue: "No repository",
                                      comment: "Group label for sessions with no resolved repo.")
            warning.heading = String(localized: "Workspace.Sidebar.RemoveAll.Title",
                                     defaultValue: "Remove \(records.count) sessions from the sidebar?",
                                     comment: "Title of the confirmation shown before removing every session in a group from the sidebar. The placeholder is a number greater than one.")
            warning.title = String(localized: "Workspace.Sidebar.RemoveAll.Message",
                                   defaultValue: "This removes the sessions in \(name) from this list. Their Copilot CLI history stays on disk.",
                                   comment: "Body of the confirmation shown before removing a group’s sessions from the sidebar. The placeholder is a repo name.")
            warning.actionLabels = [String(localized: "Workspace.Sidebar.RemoveAll.Button",
                                           defaultValue: "Remove",
                                           comment: "Button that confirms removing sessions from the sidebar."),
                                    iTermLocalizedCancel()]
            warning.cancelLabel = iTermLocalizedCancel()
            warning.warningType = .kiTermWarningTypePersistent
            warning.window = rootView?.window
            guard warning.runModal() == .kiTermWarningSelection0 else { return }
        }
        store.hide(ids: records.map { $0.id })
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
