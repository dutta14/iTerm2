//
//  GitHubClient.swift
//  iTerm2SharedARC
//
//  Reads GitHub through the `gh` command line tool. Arguments always go in an array (never a
//  shell string), output is JSON only, every call has a timeout, and the last good answer of
//  each query is kept so views can show stale data when a refresh fails.
//

import Foundation

enum GitHubError: Error, Equatable {
    case ghMissing
    case notAuthenticated
    case notAuthorized(String)
    case offline
    case rateLimited(resetAt: Date?)
    case timeout
    case failed(String)

    /// Maps `gh` stderr to a state a view can explain. Order matters: SSO and scope problems also say 403.
    static func classify(stderr: String) -> GitHubError {
        let text = stderr.lowercased()
        if text.contains("gh auth login") || text.contains("not logged in") || text.contains("authentication required") {
            return .notAuthenticated
        }
        if text.contains("saml") || text.contains("sso") || text.contains("resource not accessible")
            || text.contains("gh auth refresh") || text.contains("missing required scope") {
            return .notAuthorized(firstLines(of: stderr, count: 1))
        }
        if text.contains("rate limit") || text.contains("http 429") {
            return .rateLimited(resetAt: nil)
        }
        if text.contains("http 403") {
            return .notAuthorized(firstLines(of: stderr, count: 1))
        }
        if text.contains("could not resolve host") || text.contains("network is unreachable")
            || text.contains("i/o timeout") || text.contains("no such host") || text.contains("offline")
            || text.contains("internet connection") {
            return .offline
        }
        return .failed(firstLines(of: stderr, count: 3))
    }

    /// Strips anything that looks like a token before text reaches a view or a log.
    static func redact(_ text: String) -> String {
        let pattern = "(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"
        return text.replacingOccurrences(of: pattern, with: "•••", options: .regularExpression)
    }

    static func firstLines(of text: String, count: Int) -> String {
        let lines = redact(text).split(separator: "\n", omittingEmptySubsequences: true).prefix(count)
        return String(lines.joined(separator: "\n").prefix(500))
    }
}

// MARK: - Models

struct GHRepository: Decodable, Equatable {
    let nameWithOwner: String
}

struct GHLabel: Decodable, Equatable {
    let name: String
}

struct GHUser: Decodable, Equatable {
    let login: String
}

struct PullRequestSummary: Decodable, Equatable {
    let number: Int
    let title: String
    let repository: GHRepository
    let isDraft: Bool
    let state: String
    let updatedAt: Date
    let url: String
    let author: GHUser?

    var repo: String { repository.nameWithOwner }
}

struct IssueSummary: Decodable, Equatable {
    let number: Int
    let title: String
    let repository: GHRepository
    let labels: [GHLabel]
    let state: String
    let createdAt: Date
    let updatedAt: Date
    let url: String

    var repo: String { repository.nameWithOwner }
}

struct WorkflowRun: Decodable, Equatable {
    let databaseId: Int
    let name: String?
    let displayTitle: String?
    let workflowName: String?
    let headBranch: String?
    let status: String
    let conclusion: String?
    let createdAt: Date
    let updatedAt: Date
    let url: String
    /// Not part of the JSON; filled in by the client.
    var repo: String = ""

    private enum CodingKeys: String, CodingKey {
        case databaseId, name, displayTitle, workflowName, headBranch, status, conclusion, createdAt, updatedAt, url
    }

    var isInProgress: Bool {
        return ["in_progress", "queued", "waiting", "pending", "requested"].contains(status)
    }

    var isFailed: Bool {
        return status == "completed" && ["failure", "timed_out", "startup_failure"].contains(conclusion ?? "")
    }

    var title: String {
        return workflowName ?? name ?? displayTitle ?? "Workflow"
    }
}

struct PullRequestFile: Decodable, Equatable {
    let path: String
    let additions: Int
    let deletions: Int
}

struct PullRequestReview: Decodable, Equatable {
    let author: GHUser?
    let state: String
}

struct PullRequestCheck: Decodable, Equatable {
    let name: String?
    let context: String?
    let status: String?
    let conclusion: String?
    let state: String?
    let detailsUrl: String?
    let targetUrl: String?

    var displayName: String { name ?? context ?? "Check" }

    /// Where the check's own page lives, when it has one.
    var url: URL? {
        return (detailsUrl ?? targetUrl).flatMap { URL(string: $0) }.flatMap { $0.scheme == "https" ? $0 : nil }
    }

    enum Outcome { case passing, failing, running, neutral }

    var outcome: Outcome {
        let result = (conclusion ?? state ?? "").uppercased()
        if ["SUCCESS"].contains(result) { return .passing }
        if ["FAILURE", "ERROR", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED"].contains(result) { return .failing }
        if ["NEUTRAL", "SKIPPED", "CANCELLED", "STALE"].contains(result) { return .neutral }
        return .running
    }
}

struct PullRequestBranchMatch: Decodable, Equatable {
    let number: Int
    let title: String
    let state: String
    let url: String
    let updatedAt: Date
    /// True when the head branch lives in a fork, so it only shares a name with this branch.
    var isCrossRepository: Bool? = nil
}

struct PullRequestDetail: Decodable, Equatable {
    let number: Int
    let title: String
    let body: String
    let state: String
    let isDraft: Bool
    let headRefName: String
    let baseRefName: String
    let url: String
    let author: GHUser?
    let createdAt: Date
    let labels: [GHLabel]
    let assignees: [GHUser]
    let files: [PullRequestFile]
    let reviews: [PullRequestReview]
    let statusCheckRollup: [PullRequestCheck]
}

// MARK: - Queries

enum PullRequestSegment: CaseIterable {
    case createdByMe, reviewRequested, mentioned

    var arguments: [String] {
        switch self {
        case .createdByMe: return ["--author", "@me"]
        case .reviewRequested: return ["--review-requested", "@me"]
        case .mentioned: return ["--mentions", "@me"]
        }
    }
}

enum IssueSegment: CaseIterable {
    case assignedToMe, createdByMe, mentioned

    var arguments: [String] {
        switch self {
        case .assignedToMe: return ["--assignee", "@me"]
        case .createdByMe: return ["--author", "@me"]
        case .mentioned: return ["--mentions", "@me"]
        }
    }
}

enum GitHubItemState: CaseIterable {
    case open, closed, merged, all

    var arguments: [String] {
        switch self {
        case .open: return ["--state", "open"]
        case .closed: return ["--state", "closed"]
        case .merged: return ["--merged"]
        case .all: return []
        }
    }
}

final class GitHubClient {
    static let shared = GitHubClient()

    // \z, not $: $ would accept a trailing newline.
    static let repoPattern = "^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\\z"
    static let maxResults = 100

    private let queue = DispatchQueue(label: "com.dutta14.devterminal.github", qos: .userInitiated, attributes: .concurrent)
    private let cacheLock = NSLock()
    private var cache = [String: Any]()
    private var cachedPath: String??
    private var _rateLimitedUntil: Date?
    private var rateLimitedUntil: Date? {
        get {
            cacheLock.lock()
            defer { cacheLock.unlock() }
            return _rateLimitedUntil
        }
        set {
            cacheLock.lock()
            _rateLimitedUntil = newValue
            cacheLock.unlock()
        }
    }

    static func isValid(repo: String) -> Bool {
        return repo.range(of: repoPattern, options: .regularExpression) != nil
    }

    // MARK: - Locating gh

    /// Login-shell lookup first so Homebrew and custom installs both work, then the usual places.
    func ghPath() -> String? {
        cacheLock.lock()
        if let cachedPath {
            cacheLock.unlock()
            return cachedPath
        }
        cacheLock.unlock()
        var found: String?
        if let output = Self.runProcess("/bin/zsh", ["-l", "-c", "command -v gh"], timeout: 5).output,
           let line = String(data: output, encoding: .utf8)?.split(separator: "\n").last,
           FileManager.default.isExecutableFile(atPath: String(line)) {
            found = String(line)
        }
        if found == nil {
            found = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first {
                FileManager.default.isExecutableFile(atPath: $0)
            }
        }
        cacheLock.lock()
        cachedPath = .some(found)
        cacheLock.unlock()
        return found
    }

    func forgetGHPath() {
        cacheLock.lock()
        cachedPath = nil
        cacheLock.unlock()
    }

    // MARK: - Running

    struct ProcessResult {
        var output: Data?
        var stderr: String
        var status: Int32
        var timedOut: Bool
    }

    static func runProcess(_ path: String,
                           _ arguments: [String],
                           timeout: TimeInterval,
                           directory: String? = nil,
                           extraEnvironment: [String: String] = [:]) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let directory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["NO_COLOR"] = "1"
        environment.merge(extraEnvironment) { _, new in new }
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ProcessResult(output: nil, stderr: error.localizedDescription, status: -1, timedOut: false)
        }
        let flagLock = NSLock()
        var timedOut = false
        let killer = DispatchWorkItem {
            flagLock.lock()
            timedOut = true
            flagLock.unlock()
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        var errorData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        killer.cancel()
        flagLock.lock()
        let didTimeOut = timedOut
        flagLock.unlock()
        return ProcessResult(output: data,
                             stderr: String(data: errorData, encoding: .utf8) ?? "",
                             status: process.terminationStatus,
                             timedOut: didTimeOut)
    }

    /// Blocking. Call from a background queue.
    func runGH(_ arguments: [String]) -> Result<Data, GitHubError> {
        if let until = rateLimitedUntil, until > Date() {
            return .failure(.rateLimited(resetAt: until))
        }
        guard let path = ghPath() else {
            return .failure(.ghMissing)
        }
        let result = Self.runProcess(path, arguments, timeout: 15)
        if result.timedOut {
            return .failure(.timeout)
        }
        guard result.status == 0, let output = result.output else {
            DLog("gh failed: \(GitHubError.firstLines(of: result.stderr, count: 3))")
            let error = GitHubError.classify(stderr: result.stderr)
            if case .rateLimited = error {
                let until = Date().addingTimeInterval(5 * 60)
                rateLimitedUntil = until
                return .failure(.rateLimited(resetAt: until))
            }
            return .failure(error)
        }
        return .success(output)
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = plain.date(from: text) ?? fractional.date(from: text) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Bad date \(text)"))
        }
        return decoder
    }

    private func fetch<T: Decodable>(_ type: T.Type,
                                     arguments: [String],
                                     transform: ((T) -> T)? = nil,
                                     completion: @escaping (Result<T, GitHubError>) -> Void) {
        let key = arguments.joined(separator: "\u{1f}")
        queue.async {
            var result: Result<T, GitHubError>
            switch self.runGH(arguments) {
            case .success(let data):
                do {
                    var value = try Self.decoder().decode(T.self, from: data)
                    if let transform {
                        value = transform(value)
                    }
                    self.cacheLock.lock()
                    self.cache[key] = value
                    self.cacheLock.unlock()
                    result = .success(value)
                } catch {
                    DLog("GitHubClient: decode failed: \(error)")
                    result = .failure(.failed("GitHub returned something Dev Terminal couldn’t read."))
                }
            case .failure(let error):
                result = .failure(error)
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private func cached<T>(_ type: T.Type, arguments: [String]) -> T? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[arguments.joined(separator: "\u{1f}")] as? T
    }

    // MARK: - Pull requests

    private func pullRequestArguments(segment: PullRequestSegment, state: GitHubItemState) -> [String] {
        return ["search", "prs"] + segment.arguments + state.arguments + [
            "--sort", "updated", "--limit", String(Self.maxResults),
            "--json", "number,title,repository,isDraft,updatedAt,url,state,author"
        ]
    }

    func cachedPullRequests(segment: PullRequestSegment, state: GitHubItemState) -> [PullRequestSummary]? {
        return cached([PullRequestSummary].self, arguments: pullRequestArguments(segment: segment, state: state))
    }

    func pullRequests(segment: PullRequestSegment,
                      state: GitHubItemState,
                      completion: @escaping (Result<[PullRequestSummary], GitHubError>) -> Void) {
        fetch([PullRequestSummary].self,
              arguments: pullRequestArguments(segment: segment, state: state),
              completion: completion)
    }

    func pullRequestDetail(repo: String,
                           number: Int,
                           completion: @escaping (Result<PullRequestDetail, GitHubError>) -> Void) {
        guard Self.isValid(repo: repo) else {
            completion(.failure(.failed("Invalid repository name.")))
            return
        }
        fetch(PullRequestDetail.self,
              arguments: ["pr", "view", String(number), "-R", repo, "--json",
                          "number,title,body,state,isDraft,headRefName,baseRefName,url,author,createdAt,labels,assignees,files,reviews,statusCheckRollup"],
              completion: completion)
    }

    /// The pull requests whose head is `branch`, for the header's View PR button.
    func pullRequests(forBranch branch: String,
                      repo: String,
                      completion: @escaping (Result<[PullRequestBranchMatch], GitHubError>) -> Void) {
        guard Self.isValid(repo: repo), !branch.isEmpty else {
            completion(.success([]))
            return
        }
        fetch([PullRequestBranchMatch].self,
              arguments: ["pr", "list", "-R", repo, "--head=" + branch, "--state", "all", "--limit", "5",
                          "--json", "number,title,state,url,updatedAt,isCrossRepository"],
              completion: completion)
    }

    // MARK: - Issues

    private func issueArguments(segment: IssueSegment, state: GitHubItemState) -> [String] {
        let issueState = state == .merged ? GitHubItemState.closed : state
        return ["search", "issues"] + segment.arguments + issueState.arguments + [
            "--sort", "updated", "--limit", String(Self.maxResults),
            "--json", "number,title,repository,labels,updatedAt,createdAt,url,state"
        ]
    }

    func cachedIssues(segment: IssueSegment, state: GitHubItemState) -> [IssueSummary]? {
        return cached([IssueSummary].self, arguments: issueArguments(segment: segment, state: state))
    }

    func issues(segment: IssueSegment,
                state: GitHubItemState,
                completion: @escaping (Result<[IssueSummary], GitHubError>) -> Void) {
        fetch([IssueSummary].self, arguments: issueArguments(segment: segment, state: state), completion: completion)
    }

    // MARK: - Workflow runs

    struct RepoRuns {
        var repo: String
        var result: Result<[WorkflowRun], GitHubError>
    }

    /// One `gh run list` per repo, a few at a time. Completion gets every repo's answer in input order.
    func runs(repos: [String], completion: @escaping ([RepoRuns]) -> Void) {
        let valid = repos.filter { Self.isValid(repo: $0) }
        guard !valid.isEmpty else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        var results = [RepoRuns?](repeating: nil, count: valid.count)
        let lock = NSLock()
        let group = DispatchGroup()
        let limiter = DispatchSemaphore(value: 4)
        for (index, repo) in valid.enumerated() {
            group.enter()
            queue.async {
                limiter.wait()
                defer {
                    limiter.signal()
                    group.leave()
                }
                let arguments = ["run", "list", "-R", repo, "--limit", "20", "--json",
                                 "databaseId,name,displayTitle,workflowName,headBranch,status,conclusion,createdAt,updatedAt,url"]
                var outcome: Result<[WorkflowRun], GitHubError>
                switch self.runGH(arguments) {
                case .success(let data):
                    if var runs = try? Self.decoder().decode([WorkflowRun].self, from: data) {
                        for i in runs.indices {
                            runs[i].repo = repo
                        }
                        outcome = .success(runs)
                    } else {
                        outcome = .failure(.failed("GitHub returned something Dev Terminal couldn’t read."))
                    }
                case .failure(let error):
                    outcome = .failure(error)
                }
                lock.lock()
                results[index] = RepoRuns(repo: repo, result: outcome)
                lock.unlock()
            }
        }
        group.notify(queue: .main) {
            completion(results.compactMap { $0 })
        }
    }

    enum RunAction {
        case cancel
        case rerun(failedOnly: Bool)
    }

    func perform(_ action: RunAction,
                 runId: Int,
                 repo: String,
                 completion: @escaping (Result<Void, GitHubError>) -> Void) {
        guard Self.isValid(repo: repo) else {
            completion(.failure(.failed("Invalid repository name.")))
            return
        }
        var arguments: [String]
        switch action {
        case .cancel:
            arguments = ["run", "cancel", String(runId), "-R", repo]
        case .rerun(let failedOnly):
            arguments = ["run", "rerun", String(runId), "-R", repo]
            if failedOnly {
                arguments.append("--failed")
            }
        }
        queue.async {
            let result = self.runGH(arguments)
            DispatchQueue.main.async {
                completion(result.map { _ in () })
            }
        }
    }

    /// Last 2,000 lines of the failed steps' log, without ANSI escapes.
    func failedLog(runId: Int, repo: String, completion: @escaping (Result<String, GitHubError>) -> Void) {
        guard Self.isValid(repo: repo) else {
            completion(.failure(.failed("Invalid repository name.")))
            return
        }
        queue.async {
            let result = self.runGH(["run", "view", String(runId), "--log-failed", "-R", repo])
            let mapped = result.map { data -> String in
                let text = String(decoding: data, as: UTF8.self)
                    .replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                return lines.suffix(2000).joined(separator: "\n")
            }
            DispatchQueue.main.async {
                completion(mapped)
            }
        }
    }

    // MARK: - Local git and checkout

    private static let gitPath = "/usr/bin/git"

    /// Runs `gh pr checkout` in a local clone.
    func checkoutPullRequest(number: Int,
                             repo: String,
                             directory: String,
                             completion: @escaping (Result<Void, GitHubError>) -> Void) {
        guard Self.isValid(repo: repo), let path = ghPath() else {
            completion(.failure(.ghMissing))
            return
        }
        queue.async {
            let result = Self.runProcess(path, ["pr", "checkout", String(number), "-R", repo], timeout: 60, directory: directory)
            DispatchQueue.main.async {
                if result.status == 0 {
                    completion(.success(()))
                } else {
                    completion(.failure(result.timedOut ? .timeout : GitHubError.classify(stderr: result.stderr)))
                }
            }
        }
    }

    struct BranchState: Equatable {
        var exists: Bool
        var dirty: Bool
    }

    func branchState(name: String, directory: String, completion: @escaping (BranchState) -> Void) {
        queue.async {
            let exists = Self.runProcess(Self.gitPath, ["show-ref", "--verify", "--quiet", "refs/heads/" + name],
                                         timeout: 10, directory: directory).status == 0
            let status = Self.runProcess(Self.gitPath, ["status", "--porcelain"], timeout: 10, directory: directory)
            let dirty = !(status.output ?? Data()).isEmpty
            DispatchQueue.main.async {
                completion(BranchState(exists: exists, dirty: dirty))
            }
        }
    }

    /// Creates the branch, or switches to it when `useExisting` is set.
    func switchToBranch(name: String,
                        create: Bool,
                        directory: String,
                        completion: @escaping (Result<Void, GitHubError>) -> Void) {
        queue.async {
            let arguments = create ? ["switch", "-c", name] : ["switch", name]
            let result = Self.runProcess(Self.gitPath, arguments, timeout: 15, directory: directory)
            DispatchQueue.main.async {
                if result.status == 0 {
                    completion(.success(()))
                } else {
                    completion(.failure(.failed(GitHubError.firstLines(of: result.stderr, count: 2))))
                }
            }
        }
    }

    // MARK: - Availability

    enum Availability: Equatable {
        case ready
        case failed(GitHubError)
    }

    func checkAvailability(completion: @escaping (Availability) -> Void) {
        queue.async {
            let outcome: Availability
            switch self.runGH(["auth", "status"]) {
            case .success:
                outcome = .ready
            case .failure(let error):
                if case .failed = error {
                    outcome = .failed(.notAuthenticated)
                } else {
                    outcome = .failed(error)
                }
            }
            DispatchQueue.main.async {
                completion(outcome)
            }
        }
    }

    // MARK: - Helpers for views

    static func branchSlug(_ title: String) -> String {
        var slug = ""
        for scalar in title.lowercased().unicodeScalars {
            if scalar.isASCII, (scalar.properties.numericType != nil || (scalar.value >= 97 && scalar.value <= 122)) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.count > 40 {
            slug = String(slug.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        return slug
    }

    static func issueBranchName(number: Int, title: String) -> String {
        let slug = branchSlug(title)
        return slug.isEmpty ? "fix/\(number)" : "fix/\(number)-\(slug)"
    }

    static func issuePrompt(number: Int, repo: String, title: String) -> String {
        return "Fix issue #\(number) in \(repo): \(title). Use `gh issue view \(number)` for details."
    }
}
