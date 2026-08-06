import XCTest
import GRDB
@testable import Cadence

/// Validation is what stands between a confident model and a wrecked calendar.
@MainActor
final class ProposalTests: XCTestCase {

    private var database: AppDatabase!
    private var model: AppModel!
    private var undo: UndoManager!

    private let now = Date(timeIntervalSince1970: 1_785_000_000)   // a fixed instant

    override func setUpWithError() throws {
        database = try AppDatabase.inMemory()
        model = AppModel(database: database)
        undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
    }

    // MARK: - Helpers

    @discardableResult
    private func insert(
        _ title: String,
        status: TodoStatus = .todo,
        dueAt: Date? = nil,
        deferAt: Date? = nil
    ) throws -> Todo {
        var todo = Todo(title: title, status: status, dueAt: dueAt)
        todo.deferAt = deferAt
        try database.writer.write { db in try TodoRepository.insert(db, todo) }
        return todo
    }

    private func review(
        _ changes: [ProposedChange],
        busy: [DateInterval] = [],
        allowPast: Bool = true
    ) throws -> [ReviewedChange] {
        try database.writer.read { db in
            try ProposalValidator.review(
                changes,
                db: db,
                environment: ProposalValidator.Environment(
                    now: now, busy: busy, allowPast: allowPast
                )
            )
        }
    }

    private func hour(_ offset: Double, _ length: Double = 1) -> DateInterval {
        let start = now.addingTimeInterval(offset * 3600)
        return DateInterval(start: start, duration: length * 3600)
    }

    // MARK: - Rejections

    func testSchedulingAMissingTaskIsRejected() throws {
        let reviewed = try review([
            .createBlock(id: "b", taskID: "ghost", interval: hour(1))
        ])
        XCTAssertEqual(reviewed.first?.rejection, "Task no longer exists")
    }

    func testSchedulingOverBusyTimeIsRejected() throws {
        let todo = try insert("Collide")
        let reviewed = try review(
            [.createBlock(id: "b", taskID: todo.id, interval: hour(1))],
            busy: [hour(0.5, 2)]
        )
        XCTAssertEqual(reviewed.first?.rejection, "Overlaps existing time")
    }

    func testTwoProposedBlocksCannotOverlapEachOther() throws {
        let first = try insert("First")
        let second = try insert("Second")
        let reviewed = try review([
            .createBlock(id: "b1", taskID: first.id, interval: hour(1)),
            .createBlock(id: "b2", taskID: second.id, interval: hour(1.5))
        ])
        XCTAssertNil(reviewed[0].rejection)
        XCTAssertEqual(reviewed[1].rejection, "Overlaps another proposed block")
    }

    func testSchedulingInThePastIsRejected() throws {
        let todo = try insert("Yesterday")
        let reviewed = try review(
            [.createBlock(id: "b", taskID: todo.id, interval: hour(-5))],
            allowPast: false
        )
        XCTAssertEqual(reviewed.first?.rejection, "Starts in the past")
    }

    func testBlocksSpanningMidnightAreRejected() throws {
        let todo = try insert("Marathon")
        var components = Calendar.current.dateComponents([.year, .month, .day], from: now)
        components.hour = 23
        let start = Calendar.current.date(from: components)!

        let reviewed = try review([
            .createBlock(id: "b", taskID: todo.id, interval: DateInterval(start: start, duration: 7200))
        ])
        XCTAssertEqual(reviewed.first?.rejection, "Spans midnight")
    }

    func testAbsurdDurationsAreRejected() throws {
        let todo = try insert("Too long")
        let tooShort = try review([
            .createBlock(id: "b", taskID: todo.id, interval: DateInterval(start: now, duration: 60))
        ])
        XCTAssertEqual(tooShort.first?.rejection, "Shorter than 5 minutes")
    }

    func testSchedulingACompletedTaskIsRejected() throws {
        let todo = try insert("Already done", status: .done)
        let reviewed = try review([.createBlock(id: "b", taskID: todo.id, interval: hour(1))])
        XCTAssertEqual(reviewed.first?.rejection, "Task is already done")
    }

    func testSchedulingAfterTheDueDateIsRejected() throws {
        let todo = try insert("Due today", dueAt: now)
        let reviewed = try review([
            .createBlock(id: "b", taskID: todo.id, interval: hour(72))
        ])
        XCTAssertEqual(reviewed.first?.rejection, "After the task's due date")
    }

    func testSchedulingBeforeTheDeferDateIsRejected() throws {
        let todo = try insert("Not yet", deferAt: now.addingTimeInterval(86_400 * 5))
        let reviewed = try review([.createBlock(id: "b", taskID: todo.id, interval: hour(1))])
        XCTAssertEqual(reviewed.first?.rejection, "Before the task's defer date")
    }

    func testUnknownProjectOnANewTaskIsRejected() throws {
        let reviewed = try review([
            .createTask(id: "t", draft: TaskDraft(title: "Orphan", projectID: "nope"))
        ])
        XCTAssertEqual(reviewed.first?.rejection, "Unknown project")
    }

    func testEmptyTitleIsRejected() throws {
        let reviewed = try review([.createTask(id: "t", draft: TaskDraft(title: "   "))])
        XCTAssertEqual(reviewed.first?.rejection, "Empty title")
    }

    func testUnknownStatusIsRejected() throws {
        let todo = try insert("Patch")
        var patch = TaskPatch()
        patch.status = "napping"
        let reviewed = try review([.updateTask(id: todo.id, patch: patch)])
        XCTAssertEqual(reviewed.first?.rejection, "Unknown status “napping”")
    }

    func testRejectionsAreReportedNotDropped() throws {
        let good = try insert("Fine")
        let reviewed = try review([
            .createBlock(id: "b1", taskID: good.id, interval: hour(1)),
            .createBlock(id: "b2", taskID: "ghost", interval: hour(3))
        ])
        // Both survive into the review; one is struck through.
        XCTAssertEqual(reviewed.count, 2)
        XCTAssertEqual(reviewed.filter { $0.isApplicable }.count, 1)
    }

    // MARK: - Applying

    func testApplyingWritesOnlyTheAcceptedChanges() throws {
        let todo = try insert("Schedule me")
        var proposal = Proposal(runID: "run")
        proposal.changes = try review([
            .createBlock(id: "b1", taskID: todo.id, interval: hour(1)),
            .createTask(id: "t1", draft: TaskDraft(title: "New one"))
        ])
        proposal.changes[1].isAccepted = false

        undo.beginUndoGrouping()
        let applied = model.apply(proposal)
        undo.endUndoGrouping()

        XCTAssertEqual(applied, 1)
        try database.writer.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM time_block"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task"), 1)
        }
    }

    func testRejectedChangesAreNeverApplied() throws {
        var proposal = Proposal(runID: "run")
        proposal.changes = try review([
            .createBlock(id: "b", taskID: "ghost", interval: hour(1))
        ])

        undo.beginUndoGrouping()
        XCTAssertEqual(model.apply(proposal), 0)
        undo.endUndoGrouping()
    }

    func testAppliedBlocksAreMarkedAsAIAuthored() throws {
        let todo = try insert("Schedule me")
        var proposal = Proposal(runID: "run")
        proposal.changes = try review([.createBlock(id: "b1", taskID: todo.id, interval: hour(1))])

        undo.beginUndoGrouping()
        model.apply(proposal)
        undo.endUndoGrouping()

        let source = try database.writer.read { db in
            try TodoRepository.fetchBlock(db, id: "b1")?.source
        }
        XCTAssertEqual(source, .ai, "AI-authored blocks must be distinguishable from mine")
    }

    func testAWholeTurnIsOneUndoStep() throws {
        let first = try insert("One")
        let second = try insert("Two")
        var proposal = Proposal(runID: "run")
        proposal.changes = try review([
            .createBlock(id: "b1", taskID: first.id, interval: hour(1)),
            .createBlock(id: "b2", taskID: second.id, interval: hour(3)),
            .createTask(id: "t1", draft: TaskDraft(title: "Third"))
        ])

        undo.beginUndoGrouping()
        XCTAssertEqual(model.apply(proposal), 3)
        undo.endUndoGrouping()

        try database.writer.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM time_block"), 2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task"), 3)
        }

        undo.undo()   // one press reverts the entire turn

        try database.writer.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM time_block"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task"), 2)
        }
    }

    func testUpdatePatchLeavesUntouchedFieldsAlone() throws {
        var todo = try insert("Keep my title")
        todo.estimateMinutes = 30
        try database.writer.write { db in try TodoRepository.update(db, todo) }

        var patch = TaskPatch()
        patch.estimateMinutes = .some(.some(120))

        var proposal = Proposal(runID: "run")
        proposal.changes = try review([.updateTask(id: todo.id, patch: patch)])

        undo.beginUndoGrouping()
        model.apply(proposal)
        undo.endUndoGrouping()

        let updated = try database.writer.read { db in try TodoRepository.fetch(db, id: todo.id) }
        XCTAssertEqual(updated?.estimateMinutes, 120)
        XCTAssertEqual(updated?.title, "Keep my title")
    }

    func testGhostIntervalsCoverOnlyAcceptedSchedulingChanges() throws {
        let todo = try insert("Schedule me")
        var proposal = Proposal(runID: "run")
        proposal.changes = try review([
            .createBlock(id: "b1", taskID: todo.id, interval: hour(1)),
            .createBlock(id: "b2", taskID: "ghost", interval: hour(3)),
            .createTask(id: "t1", draft: TaskDraft(title: "Not a block"))
        ])

        XCTAssertEqual(proposal.ghostIntervals.count, 1)

        proposal.changes[0].isAccepted = false
        XCTAssertTrue(proposal.ghostIntervals.isEmpty)
    }
}
