import XCTest
@testable import Cadence

/// The character is the one part of the assistant a user picks for reasons of
/// taste, so most of it cannot be asserted on. These cover the two things that
/// are not taste: that the character actually reaches the model, and that it
/// cannot quietly become a behaviour once it gets there.
@MainActor
final class PersonaTests: XCTestCase {

    // MARK: - The ones that ship

    func testBuiltInIdentifiersAreUniqueAndUsable() {
        let ids = Persona.builtIns.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "two characters share an id")
        for persona in Persona.builtIns {
            XCTAssertTrue(persona.isUsable, persona.id)
            XCTAssertTrue(persona.isBuiltIn, persona.id)
            XCTAssertFalse(persona.tagline.isEmpty, persona.id)
        }
    }

    /// The claim the whole design rests on. "Be warm and friendly" produces the
    /// assistant voice every model already defaults to; a prohibition is what is
    /// audible from the first reply. If a voice ever ships without one, it will
    /// read as characterless and nobody will be able to say why.
    func testEveryVoiceForbidsSomething() {
        for persona in Persona.builtIns {
            let voice = persona.voice.lowercased()
            let forbids = ["never", "not ", "no ", "unwilling", "only the first"]
                .contains { voice.contains($0) }
            XCTAssertTrue(forbids, "\(persona.id) tells the model what to be, not what to avoid")
        }
    }

    // MARK: - It has to reach the model, and stay a voice

    func testTheCharacterReachesTheSystemPrompt() throws {
        let prompt = try session().systemPrompt(for: .chat)
        let persona = Preferences.shared.persona
        XCTAssertTrue(prompt.contains(persona.name), prompt)
        // The voice is line-wrapped into the prompt, so a whole paragraph will
        // not match; the opening clause is enough to prove it was interpolated
        // rather than merely named.
        let opening = persona.voice.prefix(30).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(prompt.contains(opening), prompt)
    }

    /// A blunt character that decides the user does not need to hear about a
    /// clash has stopped being a character and started being a defect. The rule
    /// against it is in `promptSection` rather than in each voice, so that
    /// writing a new voice cannot leave it out.
    func testEveryCharacterCarriesTheRuleThatKeepsItOne() {
        for persona in Persona.builtIns + [Persona(
            id: "blank", name: "Blank", tagline: "", voice: "You say nothing.", dailyRemarks: 0
        )] {
            let section = persona.promptSection
            XCTAssertTrue(section.contains("never what you do"), persona.id)
            XCTAssertTrue(section.contains("the fact wins"), persona.id)
        }
    }

    // MARK: - Choosing, copying, losing

    func testAnUnknownCharacterFallsBackRatherThanGoingMute() {
        let preferences = scratchPreferences()
        preferences.personaID = "deleted-long-ago"
        XCTAssertEqual(preferences.persona.id, Persona.fallback.id)
        XCTAssertTrue(preferences.persona.isUsable)
    }

    func testACopyIsANewCharacterThatRemembersWhatItCameFrom() {
        let copy = Persona.sable.copyForEditing()
        XCTAssertNotEqual(copy.id, Persona.sable.id)
        XCTAssertEqual(copy.basedOn, Persona.sable.id)
        XCTAssertFalse(copy.isBuiltIn)
        XCTAssertEqual(copy.voice, Persona.sable.voice)
    }

    /// A copy of a copy should still point at the shipped one, so deleting it
    /// returns you to a character rather than to a dangling id.
    func testACopyOfACopyStillPointsAtTheShippedOne() {
        let second = Persona.sable.copyForEditing().copyForEditing()
        XCTAssertEqual(second.basedOn, Persona.sable.id)
    }

    func testCustomCharactersSurviveBeingWrittenAndReadBack() {
        let defaults = scratchDefaults()
        let preferences = Preferences(defaults: defaults)
        let mine = Persona.pip.copyForEditing()
        preferences.customPersonas = [mine]
        preferences.personaID = mine.id

        let reopened = Preferences(defaults: defaults)
        XCTAssertEqual(reopened.persona.id, mine.id)
        XCTAssertEqual(reopened.persona.voice, mine.voice)
        XCTAssertEqual(reopened.allPersonas.count, Persona.builtIns.count + 1)
    }

    // MARK: - How much of it there is in a day

    func testTodaysBudgetIsWhatTheCharacterHasInIt() {
        let now = Date()
        XCTAssertEqual(
            ScheduledPrompts.remainingRemarks(spent: 0, spentOn: nil, now: now, allowance: 3), 3
        )
        XCTAssertEqual(
            ScheduledPrompts.remainingRemarks(spent: 3, spentOn: now, now: now, allowance: 3), 0
        )
    }

    /// The failure this guards is the quiet one: a companion that used up
    /// yesterday's allowance and then never speaks again.
    func testYesterdaysSpendingIsNotCarriedIntoToday() {
        let now = Date()
        let yesterday = now.addingTimeInterval(-26 * 3600)
        XCTAssertEqual(
            ScheduledPrompts.remainingRemarks(
                spent: 9, spentOn: yesterday, now: now, allowance: 3
            ),
            3
        )
    }

    func testACharacterSetToNeverSaysNothingUnasked() {
        XCTAssertEqual(
            ScheduledPrompts.remainingRemarks(
                spent: 0, spentOn: nil, now: Date(), allowance: 0
            ),
            0
        )
    }

    // MARK: -

    private func session() throws -> AgentSession {
        AgentSession(model: AppModel(database: try AppDatabase.inMemory()))
    }

    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "PersonaTests.\(UUID().uuidString)")!
    }

    private func scratchPreferences() -> Preferences {
        Preferences(defaults: scratchDefaults())
    }
}
