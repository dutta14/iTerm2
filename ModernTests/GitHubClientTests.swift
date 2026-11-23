//
//  GitHubClientTests.swift
//  ModernTests
//
//  Tests for the workspace GitHub layer: decoding what `gh` prints, classifying its errors,
//  redacting tokens, and the naming helpers used when starting a session from an issue.
//

import XCTest
@testable import iTerm2SharedARC

final class GitHubClientTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        return try GitHubClient.decoder().decode(type, from: Data(json.utf8))
    }

    // MARK: Decoding

    func testDecodesPullRequestSearchResults() throws {
        let json = """
        [{"number":42,"title":"Add thing","repository":{"nameWithOwner":"dutta14/iTerm2","name":"iTerm2"},
          "isDraft":true,"state":"open","updatedAt":"2025-03-01T12:30:00Z","url":"https://github.com/dutta14/iTerm2/pull/42",
          "author":{"login":"dutta14","id":"x"}}]
        """
        let items = try decode([PullRequestSummary].self, json)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].repo, "dutta14/iTerm2")
        XCTAssertTrue(items[0].isDraft)
        XCTAssertEqual(items[0].author?.login, "dutta14")
    }

    func testDecodesFractionalSecondDates() throws {
        let json = """
        [{"number":1,"title":"t","repository":{"nameWithOwner":"a/b"},"labels":[{"name":"bug"}],"state":"open",
          "createdAt":"2025-03-01T12:30:00.123Z","updatedAt":"2025-03-02T00:00:00Z","url":"https://github.com/a/b/issues/1"}]
        """
        let items = try decode([IssueSummary].self, json)
        XCTAssertEqual(items[0].labels.map { $0.name }, ["bug"])
    }

    func testDecodesWorkflowRunsAndClassifiesThem() throws {
        let json = """
        [{"databaseId":7,"name":"CI","displayTitle":"Fix","workflowName":"Build","headBranch":"main","status":"completed",
          "conclusion":"failure","createdAt":"2025-03-01T12:00:00Z","updatedAt":"2025-03-01T12:05:00Z","url":"https://x/7"},
         {"databaseId":8,"name":null,"displayTitle":"Fix","workflowName":null,"headBranch":null,"status":"in_progress",
          "conclusion":null,"createdAt":"2025-03-01T12:00:00Z","updatedAt":"2025-03-01T12:05:00Z","url":"https://x/8"}]
        """
        let runs = try decode([WorkflowRun].self, json)
        XCTAssertTrue(runs[0].isFailed)
        XCTAssertFalse(runs[0].isInProgress)
        XCTAssertEqual(runs[0].title, "Build")
        XCTAssertTrue(runs[1].isInProgress)
        XCTAssertFalse(runs[1].isFailed)
        XCTAssertEqual(runs[1].title, "Fix")
    }

    func testCheckOutcomes() throws {
        let json = """
        [{"name":"a","status":"COMPLETED","conclusion":"SUCCESS"},
         {"name":"b","status":"COMPLETED","conclusion":"FAILURE"},
         {"context":"c","state":"PENDING"},
         {"name":"d","status":"COMPLETED","conclusion":"SKIPPED"}]
        """
        let checks = try decode([PullRequestCheck].self, json)
        XCTAssertEqual(checks.map { $0.outcome }, [.passing, .failing, .running, .neutral])
        XCTAssertEqual(checks[2].displayName, "c")
    }

    // MARK: Errors

    func testClassifiesGHErrors() {
        XCTAssertEqual(GitHubError.classify(stderr: "To get started with GitHub CLI, please run:  gh auth login"), .notAuthenticated)
        XCTAssertEqual(GitHubError.classify(stderr: "dial tcp: lookup api.github.com: no such host"), .offline)
        XCTAssertEqual(GitHubError.classify(stderr: "HTTP 403: API rate limit exceeded"), .rateLimited(resetAt: nil))
        if case .notAuthorized = GitHubError.classify(stderr: "HTTP 403: Resource protected by organization SAML enforcement") {
        } else {
            XCTFail("SSO errors should be classified as not authorized, not rate limited")
        }
        if case .rateLimited = GitHubError.classify(stderr: "HTTP 403: Forbidden") {
            XCTFail("A plain 403 must not lock out every gh call")
        }
        XCTAssertEqual(GitHubError.classify(stderr: "boom\nsecond\nthird\nfourth"), .failed("boom\nsecond\nthird"))
    }

    func testRedactsTokens() {
        let token = "ghp_" + String(repeating: "a", count: 36)
        let redacted = GitHubError.redact("failed with \(token) in header")
        XCTAssertFalse(redacted.contains(token))
        XCTAssertTrue(redacted.contains("•••"))
        XCTAssertFalse(GitHubError.redact("github_pat_" + String(repeating: "B", count: 30)).contains("github_pat_"))
    }

    // MARK: Validation and naming

    func testRepoValidation() {
        XCTAssertTrue(GitHubClient.isValid(repo: "dutta14/iTerm2"))
        XCTAssertTrue(GitHubClient.isValid(repo: "a.b/c_d-e"))
        XCTAssertFalse(GitHubClient.isValid(repo: "no-slash"))
        XCTAssertFalse(GitHubClient.isValid(repo: "a/b/c"))
        XCTAssertFalse(GitHubClient.isValid(repo: "a/b; rm -rf ~"))
        XCTAssertFalse(GitHubClient.isValid(repo: "--flag/x"
            + "\n"))
    }

    func testBranchSlug() {
        XCTAssertEqual(GitHubClient.branchSlug("Fix the Crash!!  on  launch"), "fix-the-crash-on-launch")
        XCTAssertEqual(GitHubClient.branchSlug("  --Hello--  "), "hello")
        XCTAssertEqual(GitHubClient.branchSlug("Ünïcode ⚡ title"), "n-code-title")
        XCTAssertEqual(GitHubClient.branchSlug("٣ arabic digit"), "arabic-digit")
        XCTAssertLessThanOrEqual(GitHubClient.branchSlug(String(repeating: "word ", count: 30)).count, 40)
        XCTAssertFalse(GitHubClient.branchSlug(String(repeating: "word ", count: 30)).hasSuffix("-"))
    }

    func testIssueBranchNameFallsBackWhenSlugIsEmpty() {
        XCTAssertEqual(GitHubClient.issueBranchName(number: 12, title: "Fix login"), "fix/12-fix-login")
        XCTAssertEqual(GitHubClient.issueBranchName(number: 12, title: "🔥🔥"), "fix/12")
    }

    func testIssuePromptHasNoTrailingNewline() {
        let prompt = GitHubClient.issuePrompt(number: 3, repo: "a/b", title: "Crash")
        XCTAssertTrue(prompt.contains("#3"))
        XCTAssertTrue(prompt.contains("a/b"))
        XCTAssertFalse(prompt.hasSuffix("\n"))
    }

    func testStripHTMLRemovesTagsAndComments() {
        XCTAssertEqual(PullRequestDetailPage.stripHTML("Hi <b>there</b><!-- hidden --> <img src=x>friend"), "Hi there friend")
    }

    func testRelativeFormatUsesJustNowForRecentDates() {
        let now = Date()
        XCTAssertEqual(WorkspaceFormat.relative(now.addingTimeInterval(-10), now: now),
                       WorkspaceFormat.relative(now, now: now))
    }
}
