import Foundation
import Observation

/// The two AI runs nobody asks for.
///
/// **Nightly plan** — late each evening, draft tomorrow. The proposal is
/// waiting in the morning as ghosts on the grid, to accept or throw away. The
/// point is not that the model plans better than you; it is that reviewing a
/// draft costs a fraction of what starting from an empty day costs.
///
/// **Weekly reflection** — read the week's timeline and write what it implies
/// into memory. This is the only part of the app that gets better on its own:
/// "he never finishes the admin he schedules after 3pm" is worth more to next
/// week's planning than any prompt, and it can only be learned from records
/// that now exist.
///
/// Both are off by default and both stage rather than write — an unattended run
/// that could edit the database while you sleep is not a feature anyone asked
/// for twice.
@MainActor
@Observable
final class ScheduledRuns {

    private let model: AppModel
    private let session: AgentSession
    private var timer: Task<Void, Never>?

    var nightlyPlanEnabled: Bool {
        didSet {
            UserDefaults.standard.set(nightlyPlanEnabled, forKey: Key.nightly)
            restart()
        }
    }

    var weeklyReflectionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(weeklyReflectionEnabled, forKey: Key.reflection)
            restart()
        }
    }

    /// The hour the nightly run fires, 24h. Late enough that the day is over.
    var nightlyHour: Int {
        didSet {
            UserDefaults.standard.set(nightlyHour, forKey: Key.nightlyHour)
            restart()
        }
    }

    private(set) var lastNightlyRun: Date?
    private(set) var lastReflectionRun: Date?

    init(model: AppModel, session: AgentSession) {
        self.model = model
        self.session = session
        self.nightlyPlanEnabled = UserDefaults.standard.bool(forKey: Key.nightly)
        self.weeklyReflectionEnabled = UserDefaults.standard.bool(forKey: Key.reflection)
        let hour = UserDefaults.standard.integer(forKey: Key.nightlyHour)
        self.nightlyHour = (1...23).contains(hour) ? hour : 21
        self.lastNightlyRun = UserDefaults.standard.object(forKey: Key.lastNightly) as? Date
        self.lastReflectionRun = UserDefaults.standard.object(forKey: Key.lastReflection) as? Date
    }

    // MARK: - Scheduling

    func start() {
        restart()
    }

    private func restart() {
        timer?.cancel()
        guard nightlyPlanEnabled || weeklyReflectionEnabled else { return }
        timer = Task { [weak self] in
            // A polled check rather than a fired timer: the Mac sleeps, and a
            // timer that should have fired at 21:00 while it was shut simply
            // never does. Waking up and asking "is it past the hour, and has
            // today's run happened?" survives that.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.fireIfDue()
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Runs whichever is due. Never both at once: they would fight over the one
    /// CLI process, and the second would be dropped anyway.
    func fireIfDue(now: Date = Date()) async {
        guard !session.status.isRunning else { return }
        guard session.configurationProblem == nil else { return }

        if weeklyReflectionEnabled, isReflectionDue(now: now) {
            lastReflectionRun = now
            UserDefaults.standard.set(now, forKey: Key.lastReflection)
            session.send(Self.reflectionPrompt, surface: .reflection)
            return
        }

        if nightlyPlanEnabled, isNightlyDue(now: now) {
            lastNightlyRun = now
            UserDefaults.standard.set(now, forKey: Key.lastNightly)
            session.send(Self.nightlyPrompt, surface: .nightly)
        }
    }

    func isNightlyDue(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard calendar.component(.hour, from: now) >= nightlyHour else { return false }
        guard let last = lastNightlyRun else { return true }
        return !calendar.isDate(last, inSameDayAs: now)
    }

    /// Sunday evening, and not already done this week.
    func isReflectionDue(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard calendar.component(.weekday, from: now) == 1 else { return false }
        guard calendar.component(.hour, from: now) >= nightlyHour else { return false }
        guard let last = lastReflectionRun else { return true }
        return !calendar.isDate(last, equalTo: now, toGranularity: .weekOfYear)
    }

    // MARK: - Prompts

    /// Deliberately specific about *not* inventing work. An unattended run that
    /// quietly adds tasks is how a planner loses trust in one night.
    static let nightlyPrompt = """
        Plan tomorrow. Work only from tasks that already exist — do not invent \
        any, and do not create tasks.

        1. Call get_schedule for tomorrow to see what is already committed.
        2. Call list_tasks for what is due or overdue.
        3. Call get_time_report for the last 7 days to see how much I actually \
        get through in a day, and do not schedule more than that.
        4. Call get_estimate_history for anything you are unsure about, and \
        trust it over the stated estimate.
        5. Use find_free_slots and propose_schedule for the few tasks that \
        matter most. Leave the day with room in it.

        Finish with explain: one short paragraph saying what you planned and \
        why, in plain language.
        """

    static let reflectionPrompt = """
        Look back over the past two weeks and update what you know about me.

        1. Call get_time_report for the last 14 days, with notes.
        2. Compare what I planned with what I actually recorded: which kinds of \
        work take longer than I think, which times of day I actually get things \
        done, what I keep rescheduling and never doing.
        3. Call search_memories first, then use remember to write down anything \
        durable you learned — REUSE an existing key when it revises something \
        you already knew, rather than adding a second memory that contradicts it. \
        Set source to "inferred" for anything you concluded from my records \
        rather than heard me say.
        4. Call list_stale_memories and work through what it returns. For each: \
        if the records still support it, confirm_memory; if it has changed, \
        remember with the same key; if it is simply no longer true, forget it. \
        This is the only run that revisits them, so a memory you skip here goes \
        another week unchecked.

        Only durable patterns. Not what happened this week; what it implies \
        about how I work. If two weeks of records do not support a conclusion, \
        say so and write nothing.

        Do not create, change or schedule any tasks in this run.
        """

    private enum Key {
        static let nightly = "nightlyPlanEnabled"
        static let reflection = "weeklyReflectionEnabled"
        static let nightlyHour = "nightlyPlanHour"
        static let lastNightly = "nightlyPlanLastRun"
        static let lastReflection = "weeklyReflectionLastRun"
    }
}
