//
//  WorkspaceSessionStoreTests.swift
//  ModernTests
//
//  Tests for the workspace sidebar's model: remote URL parsing, Copilot workspace.yaml
//  parsing, and how sessions group by repository.
//

import XCTest
@testable import iTerm2SharedARC

final class WorkspaceSessionStoreTests: XCTestCase {
    private func record(_ id: String,
                        repo: String?,
                        title: String = "Session",
                        updatedAt: TimeInterval) -> WorkspaceSessionRecord {
        return WorkspaceSessionRecord(id: id,
                                      copilotSessionId: nil,
                                      imported: true,
                                      repo: repo,
                                      repoSource: repo == nil ? .none : .recorded,
                                      cwd: nil,
                                      branch: nil,
                                      title: title,
                                      status: .done,
                                      updatedAt: Date(timeIntervalSince1970: updatedAt),
                                      prNumber: nil,
                                      issueNumber: nil,
                                      terminalGuid: nil)
    }

    private func makeStore() -> WorkspaceSessionStore {
        return WorkspaceSessionStore(fileURL: nil,
                                     copilotStateDirectory: URL(fileURLWithPath: "/nonexistent"))
    }

    // MARK: - RepoResolver.repoName

    func testRepoNameParsesHTTPSRemote() {
        XCTAssertEqual(RepoResolver.repoName(fromRemoteURL: "https://github.com/dutta14/iTerm2.git"),
                       "dutta14/iTerm2")
    }

    func testRepoNameParsesScpStyleRemote() {
        XCTAssertEqual(RepoResolver.repoName(fromRemoteURL: "git@github.com:dutta14/iTerm2.git\n"),
                       "dutta14/iTerm2")
    }

    func testRepoNameParsesSSHURLWithoutSuffix() {
        XCTAssertEqual(RepoResolver.repoName(fromRemoteURL: "ssh://git@github.com/gnachman/iTerm2"),
                       "gnachman/iTerm2")
    }

    func testRepoNameRejectsGarbage() {
        XCTAssertNil(RepoResolver.repoName(fromRemoteURL: ""))
        XCTAssertNil(RepoResolver.repoName(fromRemoteURL: "not a remote"))
    }

    // MARK: - CopilotWorkspaceFile.parse

    func testParseReadsFlatYAML() {
        let text = """
        id: 86b55717-f789-4ed2-9941-a49e354de651
        cwd: /Users/anindya/Documents/GitHub/dev-terminal
        repository: dutta14/iTerm2
        branch: dev-terminal-ui
        name: "Phase 1 shell"
        updated_at: 2026-11-23T22:56:36.874Z
        """
        let parsed = CopilotWorkspaceFile.parse(text)
        XCTAssertEqual(parsed?.id, "86b55717-f789-4ed2-9941-a49e354de651")
        XCTAssertEqual(parsed?.repository, "dutta14/iTerm2")
        XCTAssertEqual(parsed?.branch, "dev-terminal-ui")
        XCTAssertEqual(parsed?.name, "Phase 1 shell")
        XCTAssertNotNil(parsed?.updatedAt)
    }

    func testParseRequiresAnId() {
        XCTAssertNil(CopilotWorkspaceFile.parse("cwd: /tmp\nname: x"))
    }

    func testParseIgnoresIndentedLines() {
        let parsed = CopilotWorkspaceFile.parse("id: abc\n  repository: nested/ignored")
        XCTAssertNil(parsed?.repository)
    }

    // MARK: - Grouping

    func testGroupsAreOrderedByRecencyWithNoRepositoryLast() {
        let store = makeStore()
        store.upsert(record("a", repo: "o/old", updatedAt: 100))
        store.upsert(record("b", repo: nil, updatedAt: 900))
        store.upsert(record("c", repo: "o/new", updatedAt: 500))
        XCTAssertEqual(store.groups().map { $0.repo }, ["o/new", "o/old", nil])
    }

    func testSessionsWithinAGroupAreNewestFirst() {
        let store = makeStore()
        store.upsert(record("a", repo: "o/r", updatedAt: 100))
        store.upsert(record("b", repo: "o/r", updatedAt: 200))
        XCTAssertEqual(store.groups().first?.sessions.map { $0.id }, ["b", "a"])
    }

    func testFilterMatchesTitleOrRepository() {
        let store = makeStore()
        store.upsert(record("a", repo: "o/alpha", title: "Fix login", updatedAt: 1))
        store.upsert(record("b", repo: "o/beta", title: "Add docs", updatedAt: 2))
        XCTAssertEqual(store.groups(matching: "login").map { $0.repo }, ["o/alpha"])
        XCTAssertEqual(store.groups(matching: "BETA").map { $0.repo }, ["o/beta"])
    }

    func testHiddenRecordsAreNotListed() {
        let store = makeStore()
        store.upsert(record("a", repo: "o/r", updatedAt: 1))
        store.hide(id: "a")
        XCTAssertTrue(store.groups().isEmpty)
    }

    func testHidingSeveralRecordsLeavesTheRestListed() {
        let store = makeStore()
        store.upsert(record("a", repo: "o/r", updatedAt: 1))
        store.upsert(record("b", repo: "o/r", updatedAt: 2))
        store.upsert(record("c", repo: "o/r", updatedAt: 3))
        store.hide(ids: ["a", "c"])
        XCTAssertEqual(store.groups().flatMap { $0.sessions.map { $0.id } }, ["b"])
    }

    func testManualRepoAssignmentMovesTheSession() {
        let store = makeStore()
        store.upsert(record("a", repo: nil, updatedAt: 1))
        store.setRepo("o/r", forId: "a")
        XCTAssertEqual(store.groups().map { $0.repo }, ["o/r"])
        XCTAssertEqual(store.records.first?.repoSource, .manual)
    }

    func testOpenSessionHidesItsImportedRecord() {
        let store = makeStore()
        var imported = record("copilot-1", repo: "o/r", updatedAt: 1)
        imported.copilotSessionId = "1"
        store.upsert(imported)
        var live = record("live-1", repo: "o/r", updatedAt: 2)
        live.copilotSessionId = "1"
        live.imported = false
        store.setLiveRecords([live])
        XCTAssertEqual(store.groups().first?.sessions.map { $0.id }, ["live-1"])
    }

    // MARK: - importCopilotSessions

    private func writeCopilotSession(_ id: String, in root: URL, events: String?) throws {
        let dir = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "id: \(id)\ncwd: /tmp\nname: Session \(id)\n".write(to: dir.appendingPathComponent("workspace.yaml"),
                                                                 atomically: true,
                                                                 encoding: .utf8)
        if let events {
            try events.write(to: dir.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
        }
    }

    func testImportSkipsSessionsCopilotCannotResume() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let talked = "11111111-1111-1111-1111-111111111111"
        let empty = "22222222-2222-2222-2222-222222222222"
        let noEvents = "33333333-3333-3333-3333-333333333333"
        try writeCopilotSession(talked, in: root, events: "{\"type\":\"user.message\",\"data\":{}}\n")
        try writeCopilotSession(empty, in: root, events: "{\"type\":\"session.start\"}\n")
        try writeCopilotSession(noEvents, in: root, events: nil)
        let store = WorkspaceSessionStore(fileURL: nil, copilotStateDirectory: root)

        store.importCopilotSessions()
        let flushed = expectation(description: "main queue drained")
        DispatchQueue.main.async { flushed.fulfill() }
        wait(for: [flushed], timeout: 5)

        XCTAssertEqual(store.visibleRecords.compactMap { $0.copilotSessionId }, [talked])
    }

    func testOpenResumedSessionReplacesItsStoredRow() {
        let store = makeStore()
        var stored = record("a", repo: "o/r", updatedAt: 1)
        stored.copilotSessionId = "sid"
        store.upsert(stored)
        var live = record("live-1", repo: "o/r", updatedAt: 2)
        live.copilotSessionId = "sid"
        store.setLiveRecords([live])

        XCTAssertEqual(store.visibleRecords.map { $0.id }, ["live-1"])
    }

    func testImportMovesAnExistingSessionWhenItsWorkingDirectoryChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "44444444-4444-4444-4444-444444444444"
        let events = "{\"type\":\"user.message\",\"data\":{}}\n"
        try writeCopilotSession(id, in: root, events: events)
        let store = WorkspaceSessionStore(fileURL: nil, copilotStateDirectory: root)
        func importAndWait() {
            store.importCopilotSessions()
            let flushed = expectation(description: "main queue drained")
            DispatchQueue.main.async { flushed.fulfill() }
            wait(for: [flushed], timeout: 5)
        }
        importAndWait()
        XCTAssertEqual(store.records.first?.cwd, "/tmp")

        try "id: \(id)\ncwd: /var\nrepository: o/moved\nname: Renamed\n".write(
            to: root.appendingPathComponent(id).appendingPathComponent("workspace.yaml"),
            atomically: true,
            encoding: .utf8)
        importAndWait()

        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.cwd, "/var")
        XCTAssertEqual(store.records.first?.repo, "o/moved")
        XCTAssertEqual(store.records.first?.title, "Renamed")
    }
}
