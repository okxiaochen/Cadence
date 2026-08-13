import XCTest
import GRDB
@testable import Cadence

/// Manual order: what dragging one row between two others has to do.
final class ReorderTests: XCTestCase {

    private var database: AppDatabase!

    override func setUpWithError() throws {
        database = try AppDatabase.inMemory()
    }

    @discardableResult
    private func insert(_ title: String, parentID: String? = nil) throws -> Todo {
        try database.writer.write { db in
            try TodoRepository.insert(db, Todo(title: title, parentID: parentID))
        }
    }

    private func order() throws -> [String] {
        try database.writer.read { db in
            try TodoRepository.fetchDetails(db, query: TodoQuery(selection: .smart(.anytime)))
        }
        .sorted { $0.todo.sortOrder < $1.todo.sortOrder }
        .map(\.todo.title)
    }

    func testDroppingBelowATaskPutsItDirectlyAfter() throws {
        let a = try insert("A")
        try insert("B")
        let c = try insert("C")

        try database.writer.write { db in
            try TodoRepository.reorder(db, ids: [c.id], relativeTo: a.id, placeAfter: true)
        }
        XCTAssertEqual(try order(), ["A", "C", "B"])
    }

    func testDroppingAboveTheFirstTaskPutsItFirst() throws {
        let a = try insert("A")
        try insert("B")
        let c = try insert("C")

        try database.writer.write { db in
            try TodoRepository.reorder(db, ids: [c.id], relativeTo: a.id, placeAfter: false)
        }
        XCTAssertEqual(try order(), ["C", "A", "B"])
    }

    func testMovingSeveralKeepsTheOrderTheyWereGivenIn() throws {
        let a = try insert("A")
        try insert("B")
        let c = try insert("C")
        let d = try insert("D")

        try database.writer.write { db in
            try TodoRepository.reorder(db, ids: [c.id, d.id], relativeTo: a.id, placeAfter: true)
        }
        XCTAssertEqual(try order(), ["A", "C", "D", "B"])
    }

    func testRepeatedInsertsIntoTheSameGapKeepWorking() throws {
        let a = try insert("A")
        let b = try insert("B")

        // Each drop halves the gap; without a renumber the doubles run out.
        for index in 0..<80 {
            let moved = try insert("x\(index)")
            try database.writer.write { db in
                try TodoRepository.reorder(db, ids: [moved.id], relativeTo: a.id, placeAfter: true)
            }
        }

        let titles = try order()
        XCTAssertEqual(titles.first, "A")
        XCTAssertEqual(titles.last, "B")
        XCTAssertEqual(titles.count, 82)
        XCTAssertEqual(Set(titles).count, 82)
        // Every neighbour is distinct: a collapsed gap would tie them and the
        // list would shuffle on every reload.
        let orders = try database.writer.read { db in
            try Double.fetchAll(db, sql: "SELECT sortOrder FROM task ORDER BY sortOrder")
        }
        XCTAssertEqual(Set(orders).count, orders.count, "sort orders stayed distinct")
    }

    func testATaskDroppedAmongSubtasksJoinsThatParent() throws {
        let parent = try insert("Ship v2")
        let child = try insert("Write docs", parentID: parent.id)
        let loose = try insert("Update the README")

        try database.writer.write { db in
            try TodoRepository.reorder(db, ids: [loose.id], relativeTo: child.id, placeAfter: true)
        }
        let moved = try database.writer.read { db in try TodoRepository.fetch(db, id: loose.id) }
        XCTAssertEqual(moved?.parentID, parent.id)
    }

    func testDroppingATaskOnItselfChangesNothing() throws {
        let a = try insert("A")
        let b = try insert("B")
        let before = try order()

        try database.writer.write { db in
            try TodoRepository.reorder(db, ids: [a.id], relativeTo: a.id, placeAfter: true)
        }
        XCTAssertEqual(try order(), before)
        XCTAssertEqual(b.title, "B")
    }
}
