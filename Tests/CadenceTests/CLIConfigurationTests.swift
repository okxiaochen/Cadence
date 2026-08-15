import XCTest
@testable import Cadence

/// The presets carry flags read from each CLI's own `--help`, not guessed. The
/// point of the abstraction is that a user on Gemini or Cursor gets the same
/// assistant a user on Claude Code does — so what must not vary is that the
/// rules reach the model at all.
final class CLIConfigurationTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: "cadence.cli.tests.\(UUID().uuidString)")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.description)
        defaults = nil
    }

    // MARK: - Decoding an older stored config

    /// The trap this hand-written decoder exists for: the synthesised one
    /// throws on a key it has not seen, `load` swallows that with `try?`, and
    /// every user who had configured a command would silently have been reset
    /// to `claude`.
    func testAConfigStoredBeforeTheNewFieldsExistedKeepsItsCommand() throws {
        let old = """
        {"command": "my-wrapper", "arguments": ["-p"], \
        "workingDirectory": "/tmp", "timeoutSeconds": 300, "transport": "mcp"}
        """
        defaults.set(Data(old.utf8), forKey: CLIConfiguration.key)

        let loaded = CLIConfiguration.load(from: defaults)
        XCTAssertEqual(loaded.command, "my-wrapper")
        XCTAssertEqual(loaded.workingDirectory, "/tmp")
        XCTAssertEqual(loaded.timeoutSeconds, 300)
    }

    func testMissingFieldsFallBackToTheDefaultsRatherThanFailing() throws {
        defaults.set(Data(#"{"command": "claude"}"#.utf8), forKey: CLIConfiguration.key)
        let loaded = CLIConfiguration.load(from: defaults)
        XCTAssertEqual(
            loaded.systemPromptArguments,
            CLIConfiguration.Preset.claudeCode.systemPromptArguments
        )
        XCTAssertEqual(loaded.transport, .mcp)
    }

    /// Output format used to be appended in code; anyone configured before it
    /// moved out has the older default stored.
    func testTheOldDefaultArgumentsAreUpgradedInPlace() throws {
        defaults.set(Data(#"{"command": "claude", "arguments": ["-p"]}"#.utf8),
                     forKey: CLIConfiguration.key)
        XCTAssertEqual(
            CLIConfiguration.load(from: defaults).arguments,
            CLIConfiguration.Preset.claudeCode.arguments
        )
    }

    func testDeliberatelyCustomisedArgumentsAreLeftAlone() throws {
        defaults.set(Data(#"{"command": "claude", "arguments": ["-p", "--model", "opus"]}"#.utf8),
                     forKey: CLIConfiguration.key)
        XCTAssertEqual(
            CLIConfiguration.load(from: defaults).arguments,
            ["-p", "--model", "opus"]
        )
    }

    func testRoundTripping() throws {
        var configuration = CLIConfiguration.Preset.gemini.configuration
        configuration.timeoutSeconds = 45
        configuration.save(to: defaults)
        XCTAssertEqual(CLIConfiguration.load(from: defaults), configuration)
    }

    // MARK: - Presets

    func testEveryPresetIsRecognisedFromItsOwnFields() {
        for preset in CLIConfiguration.Preset.allCases where preset != .custom {
            XCTAssertEqual(preset.configuration.preset, preset, preset.rawValue)
        }
    }

    func testEditingAPresetAwayFromItsFlagsMakesItCustom() {
        // Derived rather than stored, so the label cannot claim something the
        // arguments contradict.
        var configuration = CLIConfiguration.Preset.claudeCode.configuration
        configuration.arguments += ["--model", "opus"]
        XCTAssertEqual(configuration.preset, .custom)
    }

    /// Only Claude Code can be handed a server per run. Cadence's port is new
    /// every run, and a settings file written by an `mcp` subcommand cannot
    /// follow it.
    func testOnlyClaudeCodeDefaultsToTheMCPTransport() {
        XCTAssertEqual(CLIConfiguration.Preset.claudeCode.transport, .mcp)
        for preset in [CLIConfiguration.Preset.gemini, .cursor] {
            XCTAssertEqual(preset.transport, .json, preset.rawValue)
            XCTAssertTrue(preset.mcpArguments.isEmpty, preset.rawValue)
        }
    }

    func testEveryPresetSubstitutesTheSystemPromptSomehow() {
        // The rules Cadence compiles in are the whole assistant. A preset that
        // neither passes them as a flag nor leaves the prompt to carry them
        // would ship a model with tools and no instructions.
        for preset in CLIConfiguration.Preset.allCases {
            let carriesFlag = preset.systemPromptArguments.contains { $0.contains("{system}") }
            let fallsBackToPrompt = preset.systemPromptArguments.isEmpty
            XCTAssertTrue(carriesFlag || fallsBackToPrompt, preset.rawValue)
        }
    }

    func testMCPArgumentsCarryBothPlaceholdersOrNone() {
        for preset in CLIConfiguration.Preset.allCases {
            guard !preset.mcpArguments.isEmpty else { continue }
            let joined = preset.mcpArguments.joined(separator: " ")
            XCTAssertTrue(joined.contains("{config}"), preset.rawValue)
            XCTAssertTrue(joined.contains("{tools}"), preset.rawValue)
        }
    }

    // MARK: - The prompt fallback

    @MainActor
    func testThePrependedPromptKeepsTheRulesAboveAVisibleBreak() {
        let combined = AgentSession.prependingSystemPrompt("RULES", to: "do the thing")
        XCTAssertTrue(combined.hasPrefix("RULES"))
        XCTAssertTrue(combined.hasSuffix("do the thing"))
        XCTAssertTrue(combined.contains("---"), "without a break the rules read as the request")
    }

    // MARK: - Reading whatever envelope came back

    @MainActor
    func testClaudeCodesEnvelopeIsUnwrapped() {
        XCTAssertEqual(
            AgentSession.parseFinalText(from: #"{"result": "Planned your day."}"#),
            "Planned your day."
        )
    }

    @MainActor
    func testPlainTextIsLeftAlone() {
        XCTAssertEqual(AgentSession.parseFinalText(from: "  Planned your day.\n"),
                       "Planned your day.")
    }

    /// Gemini reports failures like this, and handing the user a JSON blob to
    /// interpret is worse than telling them what went wrong.
    @MainActor
    func testAnErrorEnvelopeSurfacesItsMessage() {
        XCTAssertEqual(
            AgentSession.parseFinalText(
                from: #"{"session_id": "x", "error": {"type": "Error", "message": "Please set an Auth method"}}"#
            ),
            "Please set an Auth method"
        )
    }

    /// The fallback is what carries the CLIs whose success shape could not be
    /// verified: better the model's words wrapped in JSON than nothing at all.
    @MainActor
    func testAnUnrecognisedEnvelopeIsReturnedWholeRatherThanEmptied() {
        let unknown = #"{"session_id": "x", "somethingNew": "the reply"}"#
        XCTAssertEqual(AgentSession.parseFinalText(from: unknown), unknown)
    }
}
