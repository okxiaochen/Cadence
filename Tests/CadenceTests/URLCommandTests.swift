import XCTest
@testable import Cadence

/// `cadence://` — the scripting entry point.
final class URLCommandTests: XCTestCase {

    private func command(_ string: String) -> URLCommand? {
        URL(string: string).flatMap(URLCommand.init)
    }

    func testAddCarriesTheWholeCaptureGrammar() throws {
        guard case .add(let text)? = command(
            "cadence://add?text=Fix%20the%20flaky%20test%20%23backend%20~1h%20tomorrow"
        ) else { return XCTFail("expected an add") }

        // The point of passing the raw text through: the parser the composer
        // uses is the parser a script gets.
        let parsed = CaptureParser.parse(text)
        XCTAssertEqual(parsed.title, "Fix the flaky test")
        XCTAssertEqual(parsed.tagNames, ["backend"])
        XCTAssertEqual(parsed.estimateMinutes, 60)
        XCTAssertNotNil(parsed.dueAt)
    }

    func testTheHostlessFormAShellProducesAlsoWorks() {
        guard case .add(let text)? = command("cadence:///add?text=Write%20it%20down") else {
            return XCTFail("expected an add")
        }
        XCTAssertEqual(text, "Write it down")
    }

    func testTitleIsAcceptedAsAnAliasForText() {
        guard case .add(let text)? = command("cadence://add?title=From%20a%20git%20hook") else {
            return XCTFail("expected an add")
        }
        XCTAssertEqual(text, "From a git hook")
    }

    func testStartWithoutAnIDIsAllowed() {
        guard case .start(let id)? = command("cadence://start") else {
            return XCTFail("expected a start")
        }
        XCTAssertNil(id, "no id means: whatever the hotkey would have started")
    }

    func testStartWithAnID() {
        guard case .start(let id)? = command("cadence://start?id=abc") else {
            return XCTFail("expected a start")
        }
        XCTAssertEqual(id, "abc")
    }

    /// Exists so "where do I change that?" has an answer you can click.
    func testSettingsOpensUnderEitherName() {
        for url in ["cadence://settings", "cadence://preferences", "cadence:///settings"] {
            guard case .settings? = command(url) else {
                return XCTFail("expected settings from \(url)")
            }
        }
    }

    func testCommandsThatCannotActAreRejected() {
        XCTAssertNil(command("cadence://add"), "nothing to add")
        XCTAssertNil(command("cadence://add?text=%20%20"), "whitespace is not a task")
        XCTAssertNil(command("cadence://show"), "nothing to show")
        XCTAssertNil(command("cadence://nonsense"))
        XCTAssertNil(command("https://example.com/add?text=nope"), "another scheme entirely")
    }
}
