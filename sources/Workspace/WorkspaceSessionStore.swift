//
//  WorkspaceSessionStore.swift
//  iTerm2SharedARC
//
//  The sidebar's model: every session belongs to one repository. Live terminal sessions
//  and read-only imports of existing Copilot CLI sessions share one record type.
//  Persists to Application Support/Dev Terminal/workspace-sessions.json.
//

import Foundation

enum WorkspaceSessionStatus: String, Codable {
    case running
    case done
    case errored
}

enum WorkspaceRepoSource: String, Codable {
    case recorded   // Copilot wrote the repository into workspace.yaml
    case resolved   // Resolved from the working directory's git origin
    case manual     // The user chose "Move to repo…"
    case none
}

struct WorkspaceSessionRecord: Codable, Equatable {
    var id: String
    var copilotSessionId: String?
    var imported: Bool
    var repo: String?
    var repoSource: WorkspaceRepoSource
    var cwd: String?
    var branch: String?
    var title: String
    var status: WorkspaceSessionStatus
    var updatedAt: Date
    var prNumber: Int?
    var issueNumber: Int?
    /// Terminal session GUID for sessions open in a window. Live records are never persisted.
    var terminalGuid: String?
}

struct WorkspaceRepoGroup: Equatable {
    /// nil is the "No repository" group.
    var repo: String?
    var sessions: [WorkspaceSessionRecord]
}

struct CopilotWorkspaceFile: Equatable {
    var id: String
    var cwd: String?
    var repository: String?
    var branch: String?
    var name: String?
    var updatedAt: Date?

    /// workspace.yaml is flat "key: value" lines, so a full YAML parser is not needed.
    static func parse(_ text: String) -> CopilotWorkspaceFile? {
        var values = [String: String]()
        for line in text.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            let key = String(line[..<colon])
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        guard let id = values["id"], !id.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return CopilotWorkspaceFile(id: id,
                                    cwd: values["cwd"],
                                    repository: values["repository"],
                                    branch: values["branch"],
                                    name: values["name"],
                                    updatedAt: values["updated_at"].flatMap { formatter.date(from: $0) })
    }
}

final class WorkspaceSessionStore {
    static let didChangeNotification = Notification.Name("iTermWorkspaceSessionStoreDidChange")

    private(set) var records: [WorkspaceSessionRecord] = []
    private(set) var liveRecords: [WorkspaceSessionRecord] = []
    private var hiddenIds: Set<String> = []
    private let fileURL: URL?
    private let copilotStateDirectory: URL

    static let shared = WorkspaceSessionStore()

    init(fileURL: URL? = WorkspaceSessionStore.defaultFileURL(),
         copilotStateDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot/session-state")) {
        self.fileURL = fileURL
        self.copilotStateDirectory = copilotStateDirectory
        load()
    }

    private static func defaultFileURL() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first else {
            return nil
        }
        return support.appendingPathComponent("Dev Terminal/workspace-sessions.json")
    }

    // MARK: - Queries

    var visibleRecords: [WorkspaceSessionRecord] {
        let openIds = Set(liveRecords.compactMap { $0.copilotSessionId })
        let stored = records.filter { !hiddenIds.contains($0.id) && !openIds.contains($0.copilotSessionId ?? "") }
        return liveRecords + stored
    }

    /// Groups sorted by most recent activity; "No repository" is always last.
    func groups(matching filter: String = "") -> [WorkspaceRepoGroup] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = visibleRecords.filter { record in
            needle.isEmpty
                || record.title.lowercased().contains(needle)
                || (record.repo?.lowercased().contains(needle) ?? false)
        }
        let byRepo = Dictionary(grouping: filtered, by: { $0.repo })
        var groups = byRepo.map { repo, sessions in
            WorkspaceRepoGroup(repo: repo, sessions: sessions.sorted { $0.updatedAt > $1.updatedAt })
        }
        groups.sort { lhs, rhs in
            switch (lhs.repo, rhs.repo) {
            case (nil, nil): return false
            case (nil, _): return false
            case (_, nil): return true
            default:
                let l = lhs.sessions.first?.updatedAt ?? .distantPast
                let r = rhs.sessions.first?.updatedAt ?? .distantPast
                return l > r
            }
        }
        return groups
    }

    // MARK: - Mutation

    func upsert(_ record: WorkspaceSessionRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            guard records[index] != record else { return }
            records[index] = record
        } else {
            records.append(record)
        }
        saveAndNotify()
    }

    func hide(id: String) {
        hide(ids: [id])
    }

    func hide(ids: [String]) {
        guard !ids.isEmpty else { return }
        hiddenIds.formUnion(ids)
        saveAndNotify()
    }

    func setRepo(_ repo: String?, forId id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].repo = repo
        records[index].repoSource = repo == nil ? WorkspaceRepoSource.none : .manual
        saveAndNotify()
    }

    /// Sessions currently open in terminal windows. Kept in memory only.
    func setLiveRecords(_ newRecords: [WorkspaceSessionRecord]) {
        guard newRecords != liveRecords else { return }
        liveRecords = newRecords
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    // MARK: - Import

    private var importStarted = false

    func importCopilotSessionsInBackground() {
        guard !importStarted else { return }
        importStarted = true
        DispatchQueue.global(qos: .utility).async { [self] in
            importCopilotSessions()
        }
    }

    /// Reads ~/.copilot/session-state. Never modifies it. Blocking; call from a background queue.
    /// Records the user already has (including manual repo assignments) are left as they are.
    func importCopilotSessions() {
        let entries = (try? FileManager.default.contentsOfDirectory(at: copilotStateDirectory,
                                                                    includingPropertiesForKeys: nil)) ?? []
        var resolvedByDirectory = [String: RepoInfo?]()
        var imported = [WorkspaceSessionRecord]()
        let known = Set(records.compactMap { $0.copilotSessionId })
        for entry in entries {
            let file = entry.appendingPathComponent("workspace.yaml")
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let parsed = CopilotWorkspaceFile.parse(text),
                  !known.contains(parsed.id) else {
                continue
            }
            var repo = parsed.repository
            var source = WorkspaceRepoSource.recorded
            var branch = parsed.branch
            if repo == nil {
                source = .none
                if let cwd = parsed.cwd {
                    let info: RepoInfo?
                    if let cached = resolvedByDirectory[cwd] {
                        info = cached
                    } else {
                        info = RepoResolver.resolve(directory: cwd)
                        resolvedByDirectory[cwd] = info
                    }
                    if let info {
                        repo = info.repo
                        branch = branch ?? info.branch
                        source = .resolved
                    }
                }
            }
            imported.append(WorkspaceSessionRecord(id: "copilot-" + parsed.id,
                                                   copilotSessionId: parsed.id,
                                                   imported: true,
                                                   repo: repo,
                                                   repoSource: source,
                                                   cwd: parsed.cwd,
                                                   branch: branch,
                                                   title: parsed.name ?? Self.fallbackTitle(cwd: parsed.cwd),
                                                   status: .done,
                                                   updatedAt: parsed.updatedAt ?? .distantPast,
                                                   prNumber: nil,
                                                   issueNumber: nil,
                                                   terminalGuid: nil))
        }
        guard !imported.isEmpty else { return }
        DispatchQueue.main.async {
            self.records.append(contentsOf: imported)
            self.saveAndNotify()
        }
    }

    private static func fallbackTitle(cwd: String?) -> String {
        let name = cwd.map { ($0 as NSString).lastPathComponent } ?? ""
        return name.isEmpty ? "Untitled session" : name
    }

    // MARK: - Persistence

    private struct Persisted: Codable {
        var records: [WorkspaceSessionRecord]
        var hiddenIds: [String]
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let persisted = try? decoder.decode(Persisted.self, from: data) else {
            DLog("WorkspaceSessionStore: could not decode \(fileURL.path)")
            return
        }
        records = persisted.records
        hiddenIds = Set(persisted.hiddenIds)
    }

    private func saveAndNotify() {
        save()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private func save() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let persisted = Persisted(records: records, hiddenIds: hiddenIds.sorted())
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try encoder.encode(persisted).write(to: fileURL, options: .atomic)
        } catch {
            DLog("WorkspaceSessionStore: save failed: \(error)")
        }
    }
}
