//
//  WorkspaceInspectorModels.swift
//  iTerm2SharedARC
//
//  Pure logic behind the inspector panes and the minimap: tab kinds, git output parsing, unified
//  diff parsing, terminal text cleanup and minimap bucketing. Nothing here touches AppKit.
//

import Foundation

enum InspectorTabKind: String, CaseIterable {
    case changes
    case pullRequest
    case terminal
    case browser
    case files
    case sideChat

    enum Availability {
        case available
        case soon
        case later
    }

    var availability: Availability {
        switch self {
        case .changes, .terminal, .files: return .available
        case .pullRequest: return .soon
        case .browser, .sideChat: return .later
        }
    }

    /// Tabs that open by default for a new window.
    static let defaults: [InspectorTabKind] = [.changes, .terminal]
}

// MARK: - Git changes

struct GitFileChange: Equatable {
    /// One of M, A, D, R, ?
    var status: Character
    var path: String
    var oldPath: String?
    var added: Int?
    var removed: Int?
    var isBinary: Bool

    var displayName: String {
        return path
    }
}

enum GitChangeParser {
    /// Parses `git diff HEAD --name-status -z`, `git diff HEAD --numstat -z` and
    /// `git ls-files --others --exclude-standard -z` into one list ordered by path.
    static func parse(nameStatus: String, numstat: String, untracked: String) -> [GitFileChange] {
        var changes = [GitFileChange]()
        var index = [String: Int]()

        let status = nameStatus.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var i = 0
        while i < status.count {
            let code = status[i]
            let letter = code.first ?? "M"
            if letter == "R" || letter == "C", i + 2 < status.count {
                let change = GitFileChange(status: "R", path: status[i + 2], oldPath: status[i + 1],
                                           added: nil, removed: nil, isBinary: false)
                index[change.path] = changes.count
                changes.append(change)
                i += 3
            } else if i + 1 < status.count {
                let normalized: Character = ["M", "A", "D"].contains(letter) ? letter : "M"
                let change = GitFileChange(status: normalized, path: status[i + 1], oldPath: nil,
                                           added: nil, removed: nil, isBinary: false)
                index[change.path] = changes.count
                changes.append(change)
                i += 2
            } else {
                break
            }
        }

        let fields = numstat.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        i = 0
        while i < fields.count {
            let record = fields[i]
            i += 1
            guard !record.isEmpty else { continue }
            let parts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { continue }
            var path = parts[2]
            if path.isEmpty {
                // Rename: the next two fields are the old and new paths.
                guard i + 1 < fields.count else { break }
                path = fields[i + 1]
                i += 2
            }
            guard let slot = index[path] else { continue }
            if parts[0] == "-" || parts[1] == "-" {
                changes[slot].isBinary = true
            } else {
                changes[slot].added = Int(parts[0])
                changes[slot].removed = Int(parts[1])
            }
        }

        for path in untracked.split(separator: "\0", omittingEmptySubsequences: true).map(String.init) where index[path] == nil {
            index[path] = changes.count
            changes.append(GitFileChange(status: "?", path: path, oldPath: nil, added: nil, removed: nil, isBinary: false))
        }
        return changes.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

struct DiffLine: Equatable {
    enum Kind: Equatable {
        case hunk
        case added
        case removed
        case context
        case note
    }
    var kind: Kind
    var text: String
}

struct ParsedDiff: Equatable {
    var lines: [DiffLine]
    var isBinary: Bool
}

enum UnifiedDiffParser {
    static func parse(_ text: String) -> ParsedDiff {
        var lines = [DiffLine]()
        var inHunk = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                return ParsedDiff(lines: [], isBinary: true)
            }
            if line.hasPrefix("@@") {
                inHunk = true
                lines.append(DiffLine(kind: .hunk, text: line))
                continue
            }
            guard inHunk else { continue }
            if line.hasPrefix("+") {
                lines.append(DiffLine(kind: .added, text: String(line.dropFirst())))
            } else if line.hasPrefix("-") {
                lines.append(DiffLine(kind: .removed, text: String(line.dropFirst())))
            } else if line.hasPrefix("\\") {
                lines.append(DiffLine(kind: .note, text: line))
            } else if line.hasPrefix(" ") {
                lines.append(DiffLine(kind: .context, text: String(line.dropFirst())))
            } else if line.isEmpty {
                continue
            }
        }
        return ParsedDiff(lines: lines, isBinary: false)
    }
}

// MARK: - Terminal text

/// Turns the byte stream of a shell on a dumb terminal into plain text lines. It understands
/// carriage return, backspace and the few cursor sequences line editors use to redraw a line, and
/// drops every other escape sequence.
struct TerminalTextBuffer {
    private(set) var lines: [[Character]] = [[]]
    private var column = 0
    private var pending = [UInt8]()
    private let maxLines: Int

    init(maxLines: Int = 5000) {
        self.maxLines = maxLines
    }

    var text: String {
        return lines.map { String($0) }.joined(separator: "\n")
    }

    mutating func clear() {
        lines = [[]]
        column = 0
        pending = []
    }

    mutating func append(_ data: Data) {
        let bytes = pending + data
        pending = []
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            switch byte {
            case 0x1B:
                switch consumeEscape(bytes, from: i) {
                case .done(let next):
                    i = next
                    continue
                case .incomplete:
                    pending = Array(bytes[i...])
                    return
                }
            case 0x0D:
                column = 0
            case 0x0A:
                newline()
            case 0x08:
                column = max(0, column - 1)
            case 0x09:
                let target = (column / 8 + 1) * 8
                while column < target { put(" ") }
            case 0x00...0x1F, 0x7F:
                break
            default:
                // Gather a complete UTF-8 sequence before decoding.
                let length = byte < 0x80 ? 1 : byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
                if i + length > bytes.count {
                    pending = Array(bytes[i...])
                    return
                }
                if let string = String(bytes: bytes[i..<(i + length)], encoding: .utf8) {
                    for character in string { put(character) }
                }
                i += length
                continue
            }
            i += 1
        }
    }

    private enum EscapeResult {
        case done(Int)
        case incomplete
    }

    private mutating func consumeEscape(_ bytes: [UInt8], from start: Int) -> EscapeResult {
        guard start + 1 < bytes.count else { return .incomplete }
        let introducer = bytes[start + 1]
        switch introducer {
        case UInt8(ascii: "["):
            var j = start + 2
            while j < bytes.count, !(0x40...0x7E).contains(bytes[j]) { j += 1 }
            guard j < bytes.count else { return .incomplete }
            let parameters = String(bytes: bytes[(start + 2)..<j], encoding: .ascii) ?? ""
            applyCSI(parameters: parameters, final: bytes[j])
            return .done(j + 1)
        case UInt8(ascii: "]"):
            var j = start + 2
            while j < bytes.count {
                if bytes[j] == 0x07 { return .done(j + 1) }
                if bytes[j] == 0x1B, j + 1 < bytes.count, bytes[j + 1] == UInt8(ascii: "\\") { return .done(j + 2) }
                j += 1
            }
            return .incomplete
        case UInt8(ascii: "("), UInt8(ascii: ")"):
            return start + 2 < bytes.count ? .done(start + 3) : .incomplete
        default:
            return .done(start + 2)
        }
    }

    private mutating func applyCSI(parameters: String, final: UInt8) {
        let number = parameters.split(separator: ";").first.flatMap { Int($0) } ?? 0
        let count = max(1, number)
        switch final {
        case UInt8(ascii: "K"):
            var line = lines[lines.count - 1]
            if number == 2 {
                line = []
            } else if number == 0, column < line.count {
                line.removeSubrange(column...)
            } else if number == 1 {
                for k in 0..<min(column, line.count) { line[k] = " " }
            }
            lines[lines.count - 1] = line
        case UInt8(ascii: "D"):
            column = max(0, column - count)
        case UInt8(ascii: "C"):
            column += count
        case UInt8(ascii: "G"):
            column = max(0, count - 1)
        case UInt8(ascii: "P"):
            var line = lines[lines.count - 1]
            if column < line.count {
                line.removeSubrange(column..<min(line.count, column + count))
                lines[lines.count - 1] = line
            }
        default:
            break
        }
    }

    private mutating func put(_ character: Character) {
        var line = lines[lines.count - 1]
        while line.count < column { line.append(" ") }
        if column < line.count {
            line[column] = character
        } else {
            line.append(character)
        }
        column += 1
        lines[lines.count - 1] = line
    }

    private mutating func newline() {
        lines.append([])
        column = 0
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }
}

// MARK: - Minimap

struct MinimapPrompt: Equatable {
    var id: String
    var text: String
    var absoluteLine: Int64
    /// True when the response that followed was long.
    var isLong: Bool

    /// First 60 characters of the prompt, for tooltips and VoiceOver.
    var preview: String {
        let collapsed = text.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? text
        return String(collapsed.prefix(60))
    }
}

struct MinimapTick: Equatable {
    /// Indices into the prompt list. More than one means the tick is a bucket.
    var promptRange: Range<Int>
    var y: CGFloat
    var width: CGFloat

    var isBucket: Bool { promptRange.count > 1 }
}

enum MinimapModel {
    static let columnWidth: CGFloat = 12
    static let shortTickWidth: CGFloat = 8
    static let longTickWidth: CGFloat = 12
    static let preferredPitch: CGFloat = 7
    static let minimumPitch: CGFloat = 3

    /// AC-111: the minimap needs at least two prompts and never shows guessed ticks.
    static func shouldShow(promptCount: Int, enabled: Bool) -> Bool {
        return enabled && promptCount >= 2
    }

    static func ticks(for prompts: [MinimapPrompt], availableHeight: CGFloat) -> [MinimapTick] {
        guard !prompts.isEmpty, availableHeight > 0 else { return [] }
        let capacity = max(1, Int(availableHeight / minimumPitch))
        let pitch = min(preferredPitch, availableHeight / CGFloat(prompts.count))
        if prompts.count <= capacity {
            return prompts.enumerated().map { index, prompt in
                MinimapTick(promptRange: index..<(index + 1),
                            y: CGFloat(index) * max(pitch, minimumPitch),
                            width: prompt.isLong ? longTickWidth : shortTickWidth)
            }
        }
        var result = [MinimapTick]()
        for bucket in 0..<capacity {
            let lower = bucket * prompts.count / capacity
            let upper = (bucket + 1) * prompts.count / capacity
            guard lower < upper else { continue }
            let long = prompts[lower..<upper].contains { $0.isLong }
            result.append(MinimapTick(promptRange: lower..<upper,
                                      y: CGFloat(bucket) * minimumPitch,
                                      width: long ? longTickWidth : shortTickWidth))
        }
        return result
    }

    /// The latest prompt that is at or above the bottom of the visible area, which is the one the
    /// reader is looking at. Nil when no prompt has been reached yet.
    static func currentPromptIndex(prompts: [MinimapPrompt], visibleBottomAbsoluteLine: Int64) -> Int? {
        return prompts.lastIndex { $0.absoluteLine <= visibleBottomAbsoluteLine }
    }

    static func previousIndex(prompts: [MinimapPrompt], visibleTopAbsoluteLine: Int64) -> Int? {
        return prompts.lastIndex { $0.absoluteLine < visibleTopAbsoluteLine }
    }

    static func nextIndex(prompts: [MinimapPrompt], visibleTopAbsoluteLine: Int64) -> Int? {
        return prompts.firstIndex { $0.absoluteLine > visibleTopAbsoluteLine }
    }

    static func accessibilityLabel(index: Int, count: Int, preview: String) -> String {
        return String(localized: "Workspace.Minimap.Tick.A11y",
                      defaultValue: "Prompt \(index + 1) of \(count): \(preview)",
                      comment: "VoiceOver label of one minimap tick. The placeholders are the prompt's position, the number of prompts and the first characters of the prompt.")
    }
}
