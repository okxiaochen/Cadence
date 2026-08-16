import XCTest
import GRDB
@testable import Cadence

/// Built-in skills are never inserted into the database. That is the whole
/// design: there is no stored copy to reconcile, so shipping a better version
/// of one is a no-op, and a user's edit is the only thing that can be in the
/// user's way.
final class SkillTests: XCTestCase {

    private var database: AppDatabase!
    private var buffer: ProposalBuffer!
    private var catalog: ToolCatalog!

    override func setUpWithError() throws {
        database = try AppDatabase.inMemory()
        buffer = ProposalBuffer()
        catalog = ToolCatalog(
            database: database,
            buffer: buffer,
            context: PlanningContext(
                workdayStartHour: 9, workdayEndHour: 18, includesWeekends: false,
                defaultEstimateMinutes: 30, snapMinutes: 15, busy: []
            )
        )
    }

    private func pack(_ version: Int, _ ids: [String]) -> SkillPack {
        SkillPack(version: version, skills: ids.map {
            SkillPack.Entry(id: $0, title: $0, whenToUse: "when \($0)", body: "steps for \($0)")
        })
    }

    @discardableResult
    private func call(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
        try catalog.call(name, arguments: args) as? [String: Any] ?? [:]
    }

    private func all(_ builtIn: SkillPack) throws -> [Skill] {
        try database.writer.read { db in try SkillRepository.all(db, builtIn: builtIn) }
    }

    // MARK: - The set that ships

    func testABuiltInIsAvailableWithNothingInTheDatabase() throws {
        // The first-install case: the table is empty and the assistant still
        // knows how things are done.
        let skills = try all(pack(1, ["a", "b"]))
        XCTAssertEqual(skills.map(\.id).sorted(), ["a", "b"])
        XCTAssertTrue(skills.allSatisfy(\.isBuiltIn))
    }

    func testBuiltInsAreNeverWrittenToTheDatabase() throws {
        _ = try all(pack(1, ["a", "b"]))
        let rows = try database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM skill")
        }
        XCTAssertEqual(rows, 0, "a stored copy is the thing there would be nothing to reconcile")
    }

    func testShippingANewBuiltInSetSimplyReplacesTheOldOne() throws {
        _ = try all(pack(1, ["a"]))
        let after = try all(pack(2, ["a", "c"]))
        XCTAssertEqual(after.map(\.id).sorted(), ["a", "c"])
    }

    func testAMissingOrUnreadableBundleDegradesToNoSkills() {
        // A build problem should not stop the assistant starting.
        XCTAssertEqual(SkillPack.bundled(.main, named: "no-such-file"), .empty)
    }

    func testTheRealBundledPackIsPresentAndParses() {
        let bundled = SkillPack.bundled(Bundle(for: AppDatabase.self))
        XCTAssertGreaterThan(bundled.version, 0, "the built-in pack failed to load from the bundle")
        XCTAssertFalse(bundled.skills.isEmpty)
        for skill in bundled.skills {
            XCTAssertFalse(skill.whenToUse.isEmpty, skill.id)
            XCTAssertFalse(skill.body.isEmpty, skill.id)
        }
    }

    // MARK: - Overriding

    func testAStoredSkillWinsOverTheBuiltInOfTheSameKey() throws {
        var mine = Skill(id: "a", title: "Mine", whenToUse: "when mine", body: "my steps")
        mine.source = Skill.Source.user
        try database.writer.write { db in
            try SkillRepository.upsert(db, mine, builtIn: self.pack(1, ["a"]))
        }
        let skills = try all(pack(1, ["a"]))
        XCTAssertEqual(skills.count, 1, "the built-in must not appear alongside the override")
        XCTAssertEqual(skills.first?.body, "my steps")
        XCTAssertFalse(skills.first!.isBuiltIn)
    }

    func testOverridingRecordsWhichBuiltInVersionItWasWrittenAgainst() throws {
        let mine = Skill(id: "a", title: "Mine", whenToUse: "w", body: "b")
        try database.writer.write { db in
            try SkillRepository.upsert(db, mine, builtIn: self.pack(5, ["a"]))
        }
        let stored = try database.writer.read { db in
            try Skill.fetchOne(db, sql: "SELECT * FROM skill WHERE id = 'a'")
        }
        XCTAssertEqual(stored?.basedOnBuiltInVersion, 5)
    }

    func testASkillThatOverridesNothingRecordsNoVersion() throws {
        let mine = Skill(id: "own", title: "Mine", whenToUse: "w", body: "b")
        try database.writer.write { db in
            try SkillRepository.upsert(db, mine, builtIn: self.pack(5, ["a"]))
        }
        let stored = try database.writer.read { db in
            try Skill.fetchOne(db, sql: "SELECT * FROM skill WHERE id = 'own'")
        }
        XCTAssertNil(stored?.basedOnBuiltInVersion)
    }

    /// The edit stands — it was deliberate — but the user gets to know the
    /// shipped one moved on rather than quietly running an old fork.
    func testAnOverrideIsReportedOnceItsBuiltInHasMovedOn() throws {
        let mine = Skill(id: "a", title: "Mine", whenToUse: "w", body: "b")
        try database.writer.write { db in
            try SkillRepository.upsert(db, mine, builtIn: self.pack(1, ["a"]))
        }
        let forked = try database.writer.read { db in
            try SkillRepository.forkedFromBuiltIn(db, builtIn: self.pack(4, ["a"]))
        }
        XCTAssertEqual(forked.map(\.id), ["a"])
    }

    func testAnOverrideOfTheCurrentVersionIsNotReported() throws {
        let mine = Skill(id: "a", title: "Mine", whenToUse: "w", body: "b")
        try database.writer.write { db in
            try SkillRepository.upsert(db, mine, builtIn: self.pack(4, ["a"]))
        }
        let forked = try database.writer.read { db in
            try SkillRepository.forkedFromBuiltIn(db, builtIn: self.pack(4, ["a"]))
        }
        XCTAssertTrue(forked.isEmpty)
    }

    func testDeletingAnOverrideRestoresTheShippedVersion() throws {
        let mine = Skill(id: "a", title: "Mine", whenToUse: "w", body: "my steps")
        try database.writer.write { db in
            try SkillRepository.upsert(db, mine, builtIn: self.pack(1, ["a"]))
            _ = try SkillRepository.delete(db, id: "a")
        }
        let skills = try all(pack(1, ["a"]))
        XCTAssertEqual(skills.map(\.body), ["steps for a"])
        XCTAssertTrue(skills.first!.isBuiltIn)
    }

    // MARK: - Tools

    func testSkillToolsAreAdvertised() {
        let names = catalog.tools().map(\.name)
        for tool in ["get_skill", "save_skill", "forget_skill"] {
            XCTAssertTrue(names.contains(tool), "missing \(tool)")
        }
    }

    func testSavingThenReadingBackTheSteps() throws {
        try call("save_skill", [
            "key": "release-check", "title": "Release checks",
            "whenToUse": "Before cutting a release", "body": "1. run tests\n2. sign"
        ])
        let read = try call("get_skill", ["key": "release-check"])
        XCTAssertEqual(read["found"] as? Bool, true)
        XCTAssertEqual(read["steps"] as? String, "1. run tests\n2. sign")
        XCTAssertEqual(read["builtIn"] as? Bool, false)
    }

    func testAProcedureIsInferredUnlessTheUserDictatedIt() throws {
        try call("save_skill", [
            "key": "k", "title": "T", "whenToUse": "w", "body": "b"
        ])
        let stored = try database.writer.read { db in
            try Skill.fetchOne(db, sql: "SELECT * FROM skill WHERE id = 'k'")
        }
        XCTAssertEqual(stored?.source, Skill.Source.inferred)
    }

    func testReadingAMissingSkillSaysSoRatherThanFailing() throws {
        XCTAssertEqual(try call("get_skill", ["key": "nope"])["found"] as? Bool, false)
    }

    func testTheShippedSkillIsReachableThroughTheTool() throws {
        // End to end against the real bundle, not a fixture.
        let read = try call("get_skill", ["key": "meegle-work-items"])
        XCTAssertEqual(read["found"] as? Bool, true, "the bundled pack is not reaching the tools")
        XCTAssertEqual(read["builtIn"] as? Bool, true)
    }

    // MARK: - What reaches the prompt

    func testTheOutlineCarriesWhenToUseAndNotTheSteps() throws {
        // The body is what makes a procedure worth having, and what makes it
        // far too long to load speculatively.
        let section = try database.writer.read { db in
            try SkillRepository.promptSection(db, builtIn: self.pack(1, ["a"]))
        }
        XCTAssertTrue(section.contains("when a"), section)
        XCTAssertFalse(section.contains("steps for a"), section)
        XCTAssertTrue(section.contains("get_skill"), section)
    }

    func testNoSkillsMeansNoSection() throws {
        let section = try database.writer.read { db in
            try SkillRepository.promptSection(db, builtIn: .empty)
        }
        XCTAssertTrue(section.isEmpty)
    }
}
