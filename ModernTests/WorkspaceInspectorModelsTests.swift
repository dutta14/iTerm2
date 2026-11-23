//
//  WorkspaceInspectorModelsTests.swift
//  ModernTests
//
//  Tests for the inspector's pure logic: git output parsing, the diff parser, the plain-text
//  terminal buffer, the file tree and the minimap model.
//

import XCTest
@testable import iTerm2SharedARC

final class WorkspaceInspectorModelsTests: XCTestCase {
    // MARK: Git changes

    func testParsesModifiedAddedAndDeletedWithCounts() {
        let changes = GitChangeParser.parse(nameStatus: "M\0a.swift\0A\0b.swift\0D\0c.swift\0",
                                            numstat: "3\t1\ta.swift\010\t0\tb.swift\00\t7\tc.swift\0",
                                            untracked: "")
        XCTAssertEqual(changes.map { String($0.status) }, ["M", "A", "D"])
        XCTAssertEqual(changes[0].added, 3)
        XCTAssertEqual(changes[0].removed, 1)
        XCTAssertEqual(changes[2].removed, 7)
    }

    func testParsesRenameWithOldPath() {
        let changes = GitChangeParser.parse(nameStatus: "R100\0old name.txt\0new name.txt\0",
                                            numstat: "0\t0\t\0old name.txt\0new name.txt\0",
                                            untracked: "")
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].path, "new name.txt")
        XCTAssertEqual(changes[0].oldPath, "old name.txt")
        XCTAssertEqual(changes[0].added, 0)
    }

    func testMarksBinaryFilesAndKeepsUntracked() {
        let changes = GitChangeParser.parse(nameStatus: "M\0logo.png\0",
                                            numstat: "-\t-\tlogo.png\0",
                                            untracked: "notes.md\0")
        XCTAssertTrue(changes.first { $0.path == "logo.png" }?.isBinary ?? false)
        XCTAssertEqual(changes.first { $0.path == "notes.md" }?.status, "?")
    }

    func testSortsPathsNumerically() {
        let changes = GitChangeParser.parse(nameStatus: "", numstat: "", untracked: "f10\0f2\0")
        XCTAssertEqual(changes.map(\.path), ["f2", "f10"])
    }

    // MARK: Diffs

    func testDiffParserClassifiesLinesAndSkipsHeader() {
        let diff = UnifiedDiffParser.parse("""
        diff --git a/x b/x
        --- a/x
        +++ b/x
        @@ -1,2 +1,2 @@
         same
        -old
        +new
        """)
        XCTAssertFalse(diff.isBinary)
        XCTAssertEqual(diff.lines.map(\.kind), [.hunk, .context, .removed, .added])
        XCTAssertEqual(diff.lines.last?.text, "new")
    }

    func testDiffParserDetectsBinary() {
        XCTAssertTrue(UnifiedDiffParser.parse("Binary files a/x and b/x differ").isBinary)
    }

    // MARK: Terminal buffer

    func testBufferHandlesCarriageReturnOverwrite() {
        var buffer = TerminalTextBuffer()
        buffer.append(Data("hello\rjy".utf8))
        XCTAssertEqual(buffer.text, "jyllo")
    }

    func testBufferHandlesBackspaceErase() {
        var buffer = TerminalTextBuffer()
        buffer.append(Data("ab\u{8}\u{1B}[K".utf8))
        XCTAssertEqual(buffer.text, "a")
    }

    func testBufferDropsColorEscapes() {
        var buffer = TerminalTextBuffer()
        buffer.append(Data("\u{1B}[31mred\u{1B}[0m\n".utf8))
        XCTAssertEqual(buffer.lines.first.map { String($0) }, "red")
    }

    func testBufferKeepsSplitUTF8AcrossChunks() {
        var buffer = TerminalTextBuffer()
        let bytes = Array("é".utf8)
        buffer.append(Data([bytes[0]]))
        buffer.append(Data([bytes[1]]))
        XCTAssertEqual(buffer.text, "é")
    }

    func testBufferCapsLineCount() {
        var buffer = TerminalTextBuffer(maxLines: 10)
        for i in 0..<50 {
            buffer.append(Data("line \(i)\n".utf8))
        }
        XCTAssertLessThanOrEqual(buffer.lines.count, 11)
        XCTAssertTrue(buffer.text.contains("line 49"))
    }

    // MARK: File tree

    func testFileTreeSortsDirectoriesFirst() {
        let root = InspectorFileNode.tree(from: ["z.txt", "src/a.swift", "src/lib/b.swift", "a.txt"])
        XCTAssertEqual(root.map(\.name), ["src", "a.txt", "z.txt"])
        XCTAssertEqual(root[0].children.map(\.name), ["lib", "a.swift"])
    }

    // MARK: Minimap

    private func prompts(_ count: Int, long: Set<Int> = []) -> [MinimapPrompt] {
        return (0..<count).map { MinimapPrompt(id: "\($0)", text: "prompt \($0)\nsecond line", absoluteLine: Int64($0 * 10), isLong: long.contains($0)) }
    }

    func testMinimapNeedsTwoPromptsAndTheSetting() {
        XCTAssertFalse(MinimapModel.shouldShow(promptCount: 1, enabled: true))
        XCTAssertTrue(MinimapModel.shouldShow(promptCount: 2, enabled: true))
        XCTAssertFalse(MinimapModel.shouldShow(promptCount: 5, enabled: false))
    }

    func testMinimapUsesPreferredPitchAndLongTickWidth() {
        let ticks = MinimapModel.ticks(for: prompts(3, long: [1]), availableHeight: 400)
        XCTAssertEqual(ticks.map(\.y), [0, 7, 14])
        XCTAssertEqual(ticks.map(\.width), [8, 12, 8])
    }

    func testMinimapBucketsWhenPromptsDoNotFitAtMinimumPitch() {
        let list = prompts(100)
        let ticks = MinimapModel.ticks(for: list, availableHeight: 60)
        XCTAssertEqual(ticks.count, 20)
        XCTAssertEqual(ticks.reduce(0) { $0 + $1.promptRange.count }, 100)
        XCTAssertTrue(ticks.allSatisfy(\.isBucket))
    }

    func testMinimapCurrentAndNeighbourPrompts() {
        let list = prompts(4)
        XCTAssertNil(MinimapModel.currentPromptIndex(prompts: list.map { var p = $0; p.absoluteLine += 100; return p }, visibleBottomAbsoluteLine: 50))
        XCTAssertEqual(MinimapModel.currentPromptIndex(prompts: list, visibleBottomAbsoluteLine: 25), 2)
        XCTAssertEqual(MinimapModel.previousIndex(prompts: list, visibleTopAbsoluteLine: 20), 1)
        XCTAssertEqual(MinimapModel.nextIndex(prompts: list, visibleTopAbsoluteLine: 20), 3)
        XCTAssertNil(MinimapModel.nextIndex(prompts: list, visibleTopAbsoluteLine: 30))
    }

    func testMinimapPreviewIsFirstLineTrimmedTo60() {
        let prompt = MinimapPrompt(id: "x", text: String(repeating: "a", count: 80) + "\nrest", absoluteLine: 0, isLong: false)
        XCTAssertEqual(prompt.preview.count, 60)
    }
}
