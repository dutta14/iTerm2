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
                  event.window === self.rootView?.window,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "b" else {
                return event
            }
            self.toggleSidebar()
            return nil
        }
    }

    deinit {
        syncTimer?.invalidate()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        NotificationCenter.default.removeObserver(self)
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
        sidebarView.update(groups: store.groups(), selectedRecordId: selected, activeNav: activeNav)
    }

    private func updateHeader() {
        let session = terminal?.currentSession()
        let record = session.flatMap { s in store.liveRecords.first { $0.terminalGuid == s.guid } }
        let collapsed = sidebarView.isHidden
        let title = record?.title ?? session?.name ?? ""
        headerView.update(content: WorkspaceHeaderView.Content(repo: record?.repo,
                                                               branch: record?.branch,
                                                               title: title,
                                                               viewName: nil),
                          sidebarCollapsed: collapsed)
    }

    // MARK: - Actions

    @objc func toggleSidebar() {
        WorkspaceSettings.sidebarVisible.toggle()
        rootView?.layoutSubviews()
        refresh()
    }

    private func launchSession(directory: String?, command: String?) {
        guard let terminal else { return }
        guard let base = ProfileModel.sharedInstance().defaultProfile() else { return }
        let profile = NSMutableDictionary(dictionary: base)
        if let directory, FileManager.default.fileExists(atPath: directory) {
            profile[KEY_CUSTOM_DIRECTORY] = kProfilePreferenceInitialDirectoryCustomValue
            profile[KEY_WORKING_DIRECTORY] = directory
        }
        iTermSessionLauncher.launchBookmark(profile as? [AnyHashable: Any],
                                            in: terminal,
                                            respectTabbingMode: false) { session in
            if let command {
                session.writeTask(command + "\n")
            }
        }
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
            launchSession(directory: nil, command: "copilot")
        case .pullRequests, .issues, .automations:
            DLog("Workspace: \(item) view is not available yet")
        }
    }

    func sidebar(_ sidebar: WorkspaceSidebarView, didSelectSession record: WorkspaceSessionRecord) {
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
