import XCTest
import GRDB
@testable import Cadence

final class StoreTests: XCTestCase {

    private var database: AppDatabase!

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 5, hour: 10))!
    }

    override func setUpWithError() throws {
        database = try AppDatabase.inMemory()
    }

    // MARK: - Helpers

    @discardableResult
    private func insert(
        _ title: String,
        status: TodoStatus = .todo,
        dueAt: Date? = nil,
        deferAt: Date? = nil,
        projectID: String? = nil,
        parentID: String? = nil,
        completedAt: Date? = nil
    ) throws -> Todo {
        var todo = Todo(title: title, status: status, projectID: projectID, parentID: parentID, dueAt: dueAt)
        todo.deferAt = deferAt
        todo.completedAt = completedAt
        return try database.writer.write { db in try TodoRepository.insert(db, todo) }
    }

    private func fetch(_ query: TodoQuery) throws -> [TodoDetail] {
        try database.writer.read { db in
            try TodoRepository.fetchDetails(db, query: query, now: now, calendar: calendar)
        }
    }

    // MARK: - Schema

    func testMigrationsCreateEverySchemaObject() throws {
        try database.writer.read { db in
            for table in ["project", "tag", "task", "task_tag", "time_block", "ai_run"] {
                XCTAssertTrue(try db.tableExists(table), "missing table: \(table)")
            }
        }
    }

    func testDeletingATaskCascadesToSubtasksAndBlocks() throws {
        let parent = try insert("Ship v2")
        let child = try insert("Write docs", parentID: parent.id)
        try database.writer.write { db in
            try TodoRepository.insertBlock(db, TimeBlock(
                taskID: child.id, startAt: now, endAt: now.addingTimeInterval(3600)
            ))
            try TodoRepository.delete(db, id: parent.id)
        }
        try database.writer.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM time_block"), 0)
        }
    }

    // MARK: - What the agenda is allowed to see

    /// The agenda's window used to start at today, so a block from an earlier
    /// day was never fetched and the Overdue section stayed empty no matter
    /// what the grouping did. The window now has no lower bound.
    func testTheAgendaWindowReachesBackToOlderOpenWork() throws {
        let stale = try insert("Six weeks late")
        try database.writer.write { db in
            try TodoRepository.insertBlock(db, TimeBlock(
                taskID: stale.id,
                startAt: now.addingTimeInterval(-42 * 86_400),
                endAt: now.addingTimeInterval(-42 * 86_400 + 3600)
            ))
        }
        let blocks = try database.writer.read { db in
            try TodoRepository.scheduledBlocks(
                db,
                in: DateInterval(start: .distantPast, end: now.addingTimeInterval(86_400)),
                openOnly: true
            )
        }
        XCTAssertEqual(blocks.map(\.todo.title), ["Six weeks late"])
    }

    /// `openOnly` is what keeps that unbounded window affordable: it has to
    /// leave finished work in the past behind.
    func testOpenOnlyLeavesFinishedWorkOutOfTheAgendaWindow() throws {
        let done = try insert("Long since done", status: .done)
        let cancelled = try insert("Abandoned", status: .cancelled)
        let open = try insert("Still open")
        try database.writer.write { db in
            for todo in [done, cancelled, open] {
                try TodoRepository.insertBlock(db, TimeBlock(
                    taskID: todo.id,
                    startAt: now.addingTimeInterval(-30 * 86_400),
                    endAt: now.addingTimeInterval(-30 * 86_400 + 3600)
                ))
            }
        }
        let range = DateInterval(start: .distantPast, end: now.addingTimeInterval(86_400))
        try database.writer.read { db in
            XCTAssertEqual(
                try TodoRepository.scheduledBlocks(db, in: range, openOnly: true).map(\.todo.title),
                ["Still open"]
            )
            // The default is unchanged, so the calendar still shows what happened.
            XCTAssertEqual(try TodoRepository.scheduledBlocks(db, in: range).count, 3)
        }
    }

    func testAnAllDayTaskDueLongAgoIsStillFetched() throws {
        try insert("Due in July", dueAt: now.addingTimeInterval(-40 * 86_400))
        let details = try database.writer.read { db in
            try TodoRepository.allDay(
                db,
                in: DateInterval(start: .distantPast, end: now.addingTimeInterval(86_400))
            )
        }
        XCTAssertEqual(details.map(\.todo.title), ["Due in July"])
    }

    // MARK: - Smart lists

    func testStalledHoldsUndatedWorkNothingHasHappenedOnForAFortnight() throws {
        let old = calendar.date(byAdding: .day, value: -40, to: now)!
        let recent = calendar.date(byAdding: .day, value: -2, to: now)!

        func insertAged(_ title: String, updatedAt: Date, dueAt: Date? = nil) throws -> Todo {
            var todo = Todo(title: title, dueAt: dueAt)
            todo.createdAt = old
            todo.updatedAt = updatedAt
            return try database.writer.write { db in
                try todo.insert(db)
                return todo
            }
        }

        let forgotten = try insertAged("Rewrite the onboarding", updatedAt: old)
        _ = try insertAged("Touched last week", updatedAt: recent)
        _ = try insertAged("Has a date", updatedAt: old, dueAt: now)

        // Progress counts as something happening, even without an edit.
        let nudged = try insertAged("Chipping away at it", updatedAt: old)
        try database.writer.write { db in
            try ProgressRepository.addNote(db, taskID: nudged.id, text: "Poked at it", at: recent)
        }

        let stalled = try fetch(TodoQuery(selection: .smart(.stalled))).map(\.todo.title)
        XCTAssertEqual(stalled, [forgotten.title])
    }

    func testAnytimeIsTheCatchAllForEverythingOpen() throws {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        try insert("Plain")
        try insert("Deferred", deferAt: tomorrow)
        try insert("In progress", status: .doing)
        try insert("Finished", status: .done, completedAt: now)

        // Anytime replaced Inbox, so deferred work has nowhere else to live
        // and must show up here.
        let titles = try fetch(TodoQuery(selection: .smart(.anytime))).map(\.todo.title).sorted()
        XCTAssertEqual(titles, ["Deferred", "In progress", "Plain"])
    }

    func testMigrationFoldsLegacyInboxRowsIntoTodo() throws {
        // Stop before v3 so the row can be written the way an older build did,
        // then run the rest of the migrations as a real launch would.
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)

        var migrator = AppDatabase.migrator
        migrator.eraseDatabaseOnSchemaChange = false
        try migrator.migrate(queue, upTo: "v2_ai_run")

        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO task (id, title, notes, status, priority, sortOrder, createdAt, updatedAt)
                VALUES ('legacy', 'Old inbox row', '', 'inbox', 0, 1,
                        '2026-01-01 00:00:00.000', '2026-01-01 00:00:00.000')
                """)
        }
        XCTAssertEqual(try queue.read { db in try TodoRepository.fetch(db, id: "legacy")?.status }, .inbox)

        try migrator.migrate(queue)

        XCTAssertEqual(try queue.read { db in try TodoRepository.fetch(db, id: "legacy")?.status }, .todo)
    }

    func testTodayIncludesOverdueDoingAndTodaysBlocks() throws {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let nextWeek = calendar.date(byAdding: .day, value: 7, to: now)!

        try insert("Overdue", dueAt: yesterday)
        try insert("Due today", dueAt: now)
        try insert("In progress", status: .doing)
        try insert("Later", dueAt: nextWeek)
        let blocked = try insert("Blocked today")
        try database.writer.write { db in
            try TodoRepository.insertBlock(db, TimeBlock(
                taskID: blocked.id, startAt: now, endAt: now.addingTimeInterval(1800)
            ))
        }

        let titles = try fetch(TodoQuery(selection: .smart(.today))).map(\.todo.title).sorted()
        XCTAssertEqual(titles, ["Blocked today", "Due today", "In progress", "Overdue"])
    }

    func testDeferredTasksAreHiddenFromToday() throws {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        try insert("Deferred", dueAt: now, deferAt: tomorrow)
        try insert("Available", dueAt: now)

        let titles = try fetch(TodoQuery(selection: .smart(.today))).map(\.todo.title)
        XCTAssertEqual(titles, ["Available"])
    }

    func testUpcomingExcludesTodayAndTheDistantFuture() throws {
        try insert("Today", dueAt: now)
        try insert("In three days", dueAt: calendar.date(byAdding: .day, value: 3, to: now)!)
        try insert("In three months", dueAt: calendar.date(byAdding: .day, value: 90, to: now)!)

        let titles = try fetch(TodoQuery(selection: .smart(.upcoming))).map(\.todo.title)
        XCTAssertEqual(titles, ["In three days"])
    }

    func testLogbookShowsRecentlyCompletedOnly() throws {
        try insert("Just done", status: .done, completedAt: now)
        try insert("Ancient", status: .done,
                   completedAt: calendar.date(byAdding: .day, value: -90, to: now)!)
        try insert("Still open")

        let titles = try fetch(TodoQuery(selection: .smart(.logbook))).map(\.todo.title)
        XCTAssertEqual(titles, ["Just done"])
    }

    func testCompletedTasksAreHiddenUnlessAskedFor() throws {
        try insert("Open")
        try insert("Closed", status: .done, completedAt: now)

        var query = TodoQuery(selection: .smart(.anytime))
        XCTAssertEqual(try fetch(query).map(\.todo.title), ["Open"])

        query.showsCompleted = true
        // `anytime` is defined by open status, so completed stays out either way.
        XCTAssertEqual(try fetch(query).map(\.todo.title), ["Open"])
    }

    // MARK: - Nesting

    func testSubtasksNestUnderTheirParent() throws {
        let parent = try insert("Ship v2")
        try insert("Write docs", parentID: parent.id)
        try insert("Migrate store", parentID: parent.id)

        let rows = try fetch(TodoQuery(selection: .smart(.anytime)))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].todo.title, "Ship v2")
        XCTAssertEqual(rows[0].children.map(\.todo.title).sorted(), ["Migrate store", "Write docs"])
    }

    func testMatchedSubtaskPullsInItsParentForContext() throws {
        // The parent has no due date, so only the child matches Today.
        let parent = try insert("Ship v2")
        try insert("Write docs", dueAt: now, parentID: parent.id)

        let rows = try fetch(TodoQuery(selection: .smart(.today)))
        XCTAssertEqual(rows.map(\.todo.title), ["Ship v2"])
        XCTAssertEqual(rows[0].children.map(\.todo.title), ["Write docs"])
    }

    // MARK: - Search & tags

    func testSearchMatchesTitleAndNotes() throws {
        var withNotes = Todo(title: "Unrelated", status: .todo)
        withNotes.notes = "remember the milk"
        try database.writer.write { db in try TodoRepository.insert(db, withNotes) }
        try insert("Buy milk")
        try insert("Something else")

        var query = TodoQuery(selection: .smart(.anytime))
        query.searchText = "milk"
        XCTAssertEqual(try fetch(query).map(\.todo.title).sorted(), ["Buy milk", "Unrelated"])
    }

    func testTagsAreCaseInsensitiveAndReused() throws {
        try database.writer.write { db in
            let first = try CatalogRepository.findOrCreateTag(db, named: "Deep")
            let second = try CatalogRepository.findOrCreateTag(db, named: "deep")
            XCTAssertEqual(first.id, second.id)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag"), 1)
        }
    }

    func testFilteringByTag() throws {
        let todo = try insert("Deep work")
        try insert("Shallow work")
        try database.writer.write { db in
            let tag = try CatalogRepository.findOrCreateTag(db, named: "deep")
            try TodoRepository.setTags(db, taskID: todo.id, tagIDs: [tag.id])
        }
        let tagID = try database.writer.read { db in
            try CatalogRepository.tags(db).first!.id
        }
        XCTAssertEqual(try fetch(TodoQuery(selection: .tag(tagID))).map(\.todo.title), ["Deep work"])
    }

    func testProjectPrefixLookup() throws {
        try database.writer.write { db in
            try CatalogRepository.insert(db, Project(name: "Cadence"))
        }
        try database.writer.read { db in
            XCTAssertEqual(try CatalogRepository.findProject(db, named: "cad")?.name, "Cadence")
            XCTAssertNil(try CatalogRepository.findProject(db, named: "zzz"))
        }
    }

    // MARK: - Snapshots (undo)

    func testSnapshotRestoreRevivesADeletedTaskWithItsTags() throws {
        let todo = try insert("Important")
        let tagID = try database.writer.write { db -> String in
            let tag = try CatalogRepository.findOrCreateTag(db, named: "keep")
            try TodoRepository.setTags(db, taskID: todo.id, tagIDs: [tag.id])
            return tag.id
        }

        let before = try database.writer.read { db in
            try TodoSnapshot.capture(db, ids: [todo.id])
        }
        try database.writer.write { db in try TodoRepository.delete(db, id: todo.id) }
        XCTAssertNil(try database.writer.read { db in try TodoRepository.fetch(db, id: todo.id) })

        try database.writer.write { db in try TodoSnapshot.restore(db, before) }

        let restored = try database.writer.read { db in try TodoRepository.fetchDetail(db, id: todo.id) }
        XCTAssertEqual(restored?.todo.title, "Important")
        XCTAssertEqual(restored?.tags.map(\.id), [tagID])
    }

    func testSnapshotCaptureIncludesDescendants() throws {
        let parent = try insert("Ship v2")
        try insert("Write docs", parentID: parent.id)

        let snapshots = try database.writer.read { db in
            try TodoSnapshot.capture(db, ids: [parent.id])
        }
        XCTAssertEqual(snapshots.count, 2)
    }

    func testRestoringANeverExistedSnapshotDeletesTheTask() throws {
        let id = UUID().uuidString
        let before = try database.writer.read { db in try TodoSnapshot.capture(db, ids: [id]) }
        XCTAssertNil(before[0].todo)

        try database.writer.write { db in
            try TodoRepository.insert(db, Todo(id: id, title: "Created later"))
        }
        try database.writer.write { db in try TodoSnapshot.restore(db, before) }

        XCTAssertNil(try database.writer.read { db in try TodoRepository.fetch(db, id: id) })
    }

    // MARK: - Grouping

    func testGroupingByTagPutsATaskInEveryTagSection() throws {
        let todo = try insert("Two tags")
        try database.writer.write { db in
            let a = try CatalogRepository.findOrCreateTag(db, named: "a")
            let b = try CatalogRepository.findOrCreateTag(db, named: "b")
            try TodoRepository.setTags(db, taskID: todo.id, tagIDs: [a.id, b.id])
        }
        var query = TodoQuery(selection: .smart(.anytime))
        query.grouping = .tag

        let rows = try fetch(query)
        let sections = TodoGrouper.sections(rows: rows, query: query, now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.title), ["#a", "#b"])
        XCTAssertEqual(sections[0].items.count, 1)
    }

    func testSortingByDueDateSinksUndatedTasks() throws {
        try insert("No date")
        try insert("Soon", dueAt: calendar.date(byAdding: .day, value: 1, to: now)!)
        try insert("Later", dueAt: calendar.date(byAdding: .day, value: 5, to: now)!)

        let rows = try fetch(TodoQuery(selection: .smart(.anytime)))
        let sorted = TodoGrouper.sort(rows, by: .dueDate).map(\.todo.title)
        XCTAssertEqual(sorted, ["Soon", "Later", "No date"])
    }

    func testDueBucketing() throws {
        XCTAssertEqual(DueBucket(for: nil, now: now, calendar: calendar), DueBucket.none)
        XCTAssertEqual(
            DueBucket(for: calendar.date(byAdding: .day, value: -1, to: now)!, now: now, calendar: calendar),
            .overdue
        )
        XCTAssertEqual(DueBucket(for: now, now: now, calendar: calendar), .today)
        XCTAssertEqual(
            DueBucket(for: calendar.date(byAdding: .day, value: 1, to: now)!, now: now, calendar: calendar),
            .tomorrow
        )
    }

    // MARK: - Day grouping (Reminders-style)

    private func daySections(_ rows: [TodoDetail]) -> [TodoSection] {
        var query = TodoQuery(selection: .smart(.upcoming))
        query.grouping = .day
        return TodoGrouper.sections(rows: rows, query: query, now: now, calendar: calendar)
    }

    func testUpcomingGroupsByDayWithoutBeingAsked() {
        var query = TodoQuery(selection: .smart(.upcoming))
        XCTAssertEqual(query.grouping, TodoGrouping.none)
        XCTAssertEqual(query.resolvedGrouping, .day, "Upcoming reads as a schedule")

        query.grouping = .project
        XCTAssertEqual(query.resolvedGrouping, .project, "an explicit choice still wins")

        XCTAssertEqual(TodoQuery(selection: .smart(.anytime)).resolvedGrouping, .none)
    }

    func testDaySectionsAreNamedAndChronological() throws {
        try insert("Yesterday", dueAt: calendar.date(byAdding: .day, value: -1, to: now)!)
        try insert("Due today", dueAt: now)
        try insert("Due tomorrow", dueAt: calendar.date(byAdding: .day, value: 1, to: now)!)
        try insert("Due Friday", dueAt: calendar.date(byAdding: .day, value: 2, to: now)!)
        try insert("Next month", dueAt: calendar.date(byAdding: .day, value: 40, to: now)!)
        try insert("No date")

        var query = TodoQuery(selection: .smart(.anytime))
        query.grouping = .day
        let rows = try fetch(query)
        let sections = TodoGrouper.sections(rows: rows, query: query, now: now, calendar: calendar)

        XCTAssertEqual(sections.first?.title, "Past Due")
        XCTAssertEqual(sections.map(\.title).prefix(3), ["Past Due", "Today", "Tomorrow"])
        XCTAssertEqual(sections.last?.title, "No Due Date", "undated work sorts last")

        // 2026-08-07 is a Friday, two days out — named, not bucketed.
        XCTAssertTrue(sections.contains { $0.title.contains("Aug 7") })
    }

    func testDistantDatesCollapseIntoMonthBuckets() {
        let far = calendar.date(byAdding: .day, value: 60, to: now)!
        let bucket = DayBucket(for: far, now: now, calendar: calendar)
        if case .month = bucket {} else {
            XCTFail("expected a month bucket, got \(bucket)")
        }
        XCTAssertTrue(bucket.title(now: now, calendar: calendar).contains("October"))
    }

    func testDayBucketOrdering() {
        let keys = [
            DayBucket(for: calendar.date(byAdding: .day, value: -1, to: now)!, now: now, calendar: calendar),
            DayBucket(for: now, now: now, calendar: calendar),
            DayBucket(for: calendar.date(byAdding: .day, value: 3, to: now)!, now: now, calendar: calendar),
            DayBucket(for: nil, now: now, calendar: calendar)
        ].map(\.sortKey)
        XCTAssertEqual(keys, keys.sorted())
    }

    // MARK: - Due tasks as all-day items

    func testAllDayHoldsDatedButUntimedTasksOnly() throws {
        try insert("All day", dueAt: now)
        try insert("Due next month", dueAt: calendar.date(byAdding: .day, value: 40, to: now)!)
        try insert("No date")
        try insert("Already done", status: .done, dueAt: now, completedAt: now)

        // A task with a time block belongs in the grid, not the all-day lane —
        // after the merge it also carries a dueAt, so "has a date" is not enough.
        let timed = try insert("Timed", dueAt: now)
        try database.writer.write { db in
            try TodoRepository.insertBlock(db, TimeBlock(
                taskID: timed.id, startAt: now, endAt: now.addingTimeInterval(3600)
            ))
        }

        let week = DateInterval(
            start: calendar.startOfDay(for: now),
            end: calendar.date(byAdding: .day, value: 7, to: now)!
        )
        let allDay = try database.writer.read { db in try TodoRepository.allDay(db, in: week) }

        XCTAssertEqual(allDay.map(\.todo.title), ["All day"])
    }
}
