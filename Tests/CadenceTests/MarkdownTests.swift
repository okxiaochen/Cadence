import XCTest
@testable import Cadence

/// Classifying a line. Line-based on purpose: replies are prose, and getting a
/// nested structure slightly wrong costs far less than a parser that discards
/// text it did not expect.
final class MarkdownTests: XCTestCase {

    private func classify(_ line: String) -> MarkdownText.Block {
        MarkdownText.Block.classify(line)
    }

    func testBulletsAreRecognisedWhateverTheyAreWrittenWith() {
        XCTAssertEqual(classify("- read your issues"), .bullet("read your issues", depth: 0))
        XCTAssertEqual(classify("* read your issues"), .bullet("read your issues", depth: 0))
        XCTAssertEqual(classify("+ read your issues"), .bullet("read your issues", depth: 0))
    }

    /// An em dash opens a sentence often enough — like this one — that it must
    /// not be mistaken for a list.
    func testAnEmDashIsNotABullet() {
        XCTAssertEqual(
            classify("— 读 Meego 工作项，不过那个空间只有引导教程"),
            .plain("— 读 Meego 工作项，不过那个空间只有引导教程")
        )
    }

    func testIndentedBulletsNestOnce() {
        XCTAssertEqual(classify("  - nested"), .bullet("nested", depth: 1))
    }

    func testHeadingsCarryTheirLevel() {
        XCTAssertEqual(classify("## What I did"), .heading("What I did", level: 2))
        XCTAssertEqual(classify("#### Deeper"), .heading("Deeper", level: 4))
    }

    /// `#tag` is how this app writes tags, and a task list full of them should
    /// not turn into headings.
    func testAHashWithNoSpaceIsNotAHeading() {
        XCTAssertEqual(classify("#backend fix the thing"), .plain("#backend fix the thing"))
    }

    func testNumberedListsKeepTheirNumber() {
        XCTAssertEqual(classify("1. first"), .numbered("first", marker: "1."))
        XCTAssertEqual(classify("12. twelfth"), .numbered("twelfth", marker: "12."))
    }

    /// Otherwise "3.5 hours of work" becomes item three.
    func testADecimalIsNotAListItem() {
        XCTAssertEqual(classify("3.5 hours of work"), .plain("3.5 hours of work"))
    }

    func testQuotesAreSetAside() {
        XCTAssertEqual(classify("> he said"), .quote("he said"))
    }

    func testBlankLinesSurviveAsSpacing() {
        XCTAssertEqual(classify(""), .blank)
        XCTAssertEqual(classify("   "), .blank)
    }

    func testAParagraphIsLeftAlone() {
        let line = "Both blocks are exactly their existing estimates."
        XCTAssertEqual(classify(line), .plain(line))
    }

    func testAWholeReplyKeepsEveryLine() {
        // Nothing may be dropped: the failure worth avoiding is silently
        // losing part of an answer.
        let source = "**把外部工作拉进来**\n\n- 读你的 GitHub issues\n- 读 Meegle 工作项\n\n就这样。"
        let blocks = MarkdownText.Block.parse(source)
        XCTAssertEqual(blocks.count, source.components(separatedBy: .newlines).count)
        XCTAssertEqual(blocks.filter { if case .bullet = $0 { return true }; return false }.count, 2)
    }
}
