import XCTest
@testable import Cadence

/// The `@project` / `#tag` completion in the new-task field.
final class CompletionTests: XCTestCase {

    private let projects = [
        Project(id: "p1", name: "Cadence", colorHex: "#5E9EFF"),
        Project(id: "p2", name: "Podcast", colorHex: "#34C759"),
        Project(id: "p3", name: "Personal", colorHex: "#FF9F0A")
    ]
    private let tags = [
        Tag(id: "t1", name: "deep", colorHex: "#BF5AF2"),
        Tag(id: "t2", name: "errand", colorHex: "#5AC8FA")
    ]

    private func completion(_ text: String) -> Completion? {
        Completion.current(in: text, projects: projects, tags: tags)
    }

    func testAtOffersProjects() {
        let result = completion("Write docs @")
        XCTAssertEqual(result?.sigil, "@")
        XCTAssertEqual(result?.matches.count, 3)
    }

    func testFilteringAsYouType() {
        XCTAssertEqual(completion("Write docs @pod")?.matches.map(\.name), ["Podcast"])
    }

    func testPrefixMatchesRankAboveInteriorOnes() {
        // Typing "ca" should offer Cadence before Podcast.
        XCTAssertEqual(completion("@ca")?.matches.map(\.name), ["Cadence", "Podcast"])
    }

    func testHashOffersTags() {
        XCTAssertEqual(completion("Task #de")?.matches.map(\.name), ["deep"])
    }

    func testAnUnknownTagIsOfferedAsNew() {
        let result = completion("Task #brandnew")
        XCTAssertTrue(result?.isNewTag ?? false)
        XCTAssertTrue(result?.matches.isEmpty ?? false)
    }

    func testAnUnknownProjectIsNotOfferedAsNew() {
        // Projects are deliberate; a typo must not spawn one.
        XCTAssertFalse(completion("Task @nosuchproject")?.isNewTag ?? true)
    }

    func testNoCompletionAfterWhitespace() {
        // The token is finished, so the popup must close.
        XCTAssertNil(completion("Write docs @Cadence "))
    }

    func testEmailAddressesAreNotProjectTokens() {
        XCTAssertNil(completion("Reply to sam@example"))
    }

    func testNoSigilMeansNoCompletion() {
        XCTAssertNil(completion("Just a normal task"))
        XCTAssertNil(completion(""))
    }

    func testTheRangeCoversTheWholeTokenSoAcceptingReplacesIt() throws {
        let text = "Write docs @pod"
        let result = try XCTUnwrap(completion(text))
        XCTAssertEqual(String(text[result.range]), "@pod")

        var edited = text
        edited.replaceSubrange(result.range, with: "@Podcast ")
        XCTAssertEqual(edited, "Write docs @Podcast ")
        // And the grammar still reads it back.
        XCTAssertEqual(CaptureParser.parse(edited).projectName, "Podcast")
    }
}
