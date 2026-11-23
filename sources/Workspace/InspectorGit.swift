//
//  InspectorGit.swift
//  iTerm2SharedARC
//
//  Blocking git helpers for the inspector panes (run them off the main thread) and a debounced
//  file-system watcher.
//

import CoreServices
import Foundation

enum InspectorGit {
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    static let maxFileEntries = 20_000

    private static func run(_ arguments: [String], in directory: String, timeout: TimeInterval = 20) -> GitHubClient.ProcessResult {
        return GitHubClient.runProcess("/usr/bin/git",
                                       ["-c", "core.quotepath=false"] + arguments,
                                       timeout: timeout,
                                       directory: directory,
                                       extraEnvironment: ["GIT_OPTIONAL_LOCKS": "0"])
    }

    private static func text(_ result: GitHubClient.ProcessResult) -> String? {
        guard result.status == 0, let data = result.output else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func repoRoot(for directory: String) -> String? {
        guard let output = text(run(["rev-parse", "--show-toplevel"], in: directory, timeout: 5)) else { return nil }
        let root = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return root.isEmpty ? nil : root
    }

    private static func baseRevision(in root: String) -> String {
        return run(["rev-parse", "--verify", "-q", "HEAD"], in: root, timeout: 5).status == 0 ? "HEAD" : emptyTree
    }

    static func changes(root: String) -> [GitFileChange]? {
        let base = baseRevision(in: root)
        guard let nameStatus = text(run(["diff", base, "--name-status", "-z", "--find-renames"], in: root)),
              let numstat = text(run(["diff", base, "--numstat", "-z", "--find-renames"], in: root)) else {
            return nil
        }
        let untracked = text(run(["ls-files", "--others", "--exclude-standard", "-z"], in: root)) ?? ""
        return GitChangeParser.parse(nameStatus: nameStatus, numstat: numstat, untracked: untracked)
    }

    static func diff(root: String, change: GitFileChange) -> ParsedDiff {
        let result: GitHubClient.ProcessResult
        if change.status == "?" {
            // --no-index exits with 1 when the files differ.
            result = run(["diff", "--no-index", "--no-color", "--", "/dev/null", change.path], in: root)
        } else {
            var paths = [change.path]
            if let old = change.oldPath { paths.append(old) }
            result = run(["diff", baseRevision(in: root), "--no-color", "--find-renames", "--"] + paths, in: root)
        }
        guard let data = result.output, let string = String(data: data, encoding: .utf8) else {
            return ParsedDiff(lines: [], isBinary: false)
        }
        return UnifiedDiffParser.parse(string)
    }

    /// Tracked and untracked files, minus ignored ones, in git's order. The flag says the list was cut.
    static func files(root: String) -> (paths: [String], truncated: Bool)? {
        guard let output = text(run(["ls-files", "-co", "--exclude-standard", "-z"], in: root, timeout: 30)) else { return nil }
        var paths = [String]()
        var truncated = false
        for path in output.split(separator: "\0", omittingEmptySubsequences: true) {
            if paths.count >= maxFileEntries {
                truncated = true
                break
            }
            paths.append(String(path))
        }
        return (paths, truncated)
    }
}

/// Reports file-system changes under a directory after a quiet period. Changes inside .git only
/// count when they move HEAD or a ref, so the git commands the panes run never retrigger it.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init?(path: String, latency: TimeInterval = 0.5, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil,
                                           release: nil,
                                           copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            if list.prefix(count).contains(where: { DirectoryWatcher.isRelevant($0) }) {
                watcher.onChange()
            }
        }
        guard let stream = FSEventStreamCreate(nil,
                                               callback,
                                               &context,
                                               [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               latency,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)) else {
            return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    static func isRelevant(_ path: String) -> Bool {
        guard let range = path.range(of: "/.git/") ?? (path.hasSuffix("/.git") ? path.range(of: "/.git") : nil) else {
            return true
        }
        let inside = path[range.upperBound...]
        return inside == "HEAD" || inside.hasPrefix("refs/")
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}
