//
//  RepoResolver.swift
//  iTerm2SharedARC
//
//  Maps a working directory to a GitHub repository (owner/repo) and branch by asking git.
//

import Foundation

struct RepoInfo: Equatable {
    /// "owner/repo"
    var repo: String
    var branch: String?
    /// Root of the work tree (the main work tree for linked worktrees).
    var root: String
}

enum RepoResolver {
    /// Parses HTTPS, SSH and scp-style GitHub remotes into "owner/repo".
    static func repoName(fromRemoteURL url: String) -> String? {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("/") {
            text.removeLast()
        }
        if text.hasSuffix(".git") {
            text.removeLast(4)
        }
        let path: Substring
        if let range = text.range(of: "://") {
            let afterScheme = text[range.upperBound...]
            guard let slash = afterScheme.firstIndex(of: "/") else { return nil }
            path = afterScheme[afterScheme.index(after: slash)...]
        } else if let colon = text.firstIndex(of: ":"), text[..<colon].contains("@") {
            path = text[text.index(after: colon)...]
        } else {
            return nil
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    /// Blocking. Call from a background queue.
    static func resolve(directory: String) -> RepoInfo? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        guard let remote = git(["remote", "get-url", "origin"], in: directory),
              let repo = repoName(fromRemoteURL: remote) else {
            return nil
        }
        let branch = git(["branch", "--show-current"], in: directory)
        // The first entry of the worktree list is always the main work tree.
        let root = git(["worktree", "list", "--porcelain"], in: directory)?
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("worktree ") })
            .map { String($0.dropFirst("worktree ".count)) }
        guard let root = root ?? git(["rev-parse", "--show-toplevel"], in: directory) else {
            return nil
        }
        return RepoInfo(repo: repo,
                        branch: (branch?.isEmpty ?? true) ? nil : branch,
                        root: root)
    }

    private static func git(_ arguments: [String], in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            DLog("RepoResolver: failed to run git: \(error)")
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
