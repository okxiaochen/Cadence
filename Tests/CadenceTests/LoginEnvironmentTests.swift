import XCTest
@testable import Cadence

/// Reading the environment a terminal would have given the CLI.
///
/// The failure behind this: a wrapper (`claude-w`) resolved to a real file, so
/// it was run directly with the GUI app's environment — and it reported
/// "claude not installed", because the `claude` it looks for lives on a `PATH`
/// that only `.zshrc` knows about.
final class LoginEnvironmentTests: XCTestCase {

    private let marker = "__cadence_env__"

    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testEntriesAfterTheMarkerAreRead() {
        let parsed = LoginEnvironment.parse(data("\(marker)PATH=/a:/b\0HOME=/Users/x\0"))
        XCTAssertEqual(parsed["PATH"], "/a:/b")
        XCTAssertEqual(parsed["HOME"], "/Users/x")
    }

    /// The whole reason for the marker: rc files print banners, and an
    /// `export`-looking line in one would otherwise be read as a variable.
    func testAnythingThePromptPrintedIsDiscarded() {
        let noise = "Welcome back!\nNODE_VERSION=lies\0"
        let parsed = LoginEnvironment.parse(data("\(noise)\(marker)PATH=/real\0"))
        XCTAssertEqual(parsed["PATH"], "/real")
        XCTAssertNil(parsed["NODE_VERSION"])
    }

    func testOutputWithoutTheMarkerYieldsNothing() {
        XCTAssertTrue(LoginEnvironment.parse(data("PATH=/a\0")).isEmpty)
    }

    /// Values routinely contain `=`; only the first one separates.
    func testOnlyTheFirstEqualsSeparates() {
        let parsed = LoginEnvironment.parse(data("\(marker)LS_COLORS=di=1;34:ln=35\0"))
        XCTAssertEqual(parsed["LS_COLORS"], "di=1;34:ln=35")
    }

    /// The shell's idea of where it is, not ours — we set the directory.
    func testTheShellsOwnSessionVariablesAreDropped() {
        let parsed = LoginEnvironment.parse(
            data("\(marker)PWD=/tmp\0OLDPWD=/\0SHLVL=1\0_=/usr/bin/env\0TERM=xterm\0")
        )
        XCTAssertEqual(parsed, ["TERM": "xterm"])
    }

    func testEmptyValuesSurvive() {
        XCTAssertEqual(LoginEnvironment.parse(data("\(marker)EMPTY=\0X=1\0"))["EMPTY"], "")
    }

    func testMalformedEntriesAreSkippedRatherThanFailingTheWholeCapture() {
        let parsed = LoginEnvironment.parse(data("\(marker)no-equals-here\0=novalue\0GOOD=1\0"))
        XCTAssertEqual(parsed, ["GOOD": "1"])
    }

    // MARK: - The real shell

    /// The capture running end to end on this machine. Every login shell
    /// exports `PATH`; if it comes back empty the capture is broken.
    func testARealLoginShellReportsAPath() throws {
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else {
            throw XCTSkip("no zsh here")
        }
        XCTAssertFalse(
            LoginEnvironment.searchPaths.isEmpty,
            "the login shell exported no PATH — the capture found no marker"
        )
    }
}
