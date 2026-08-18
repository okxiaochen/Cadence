import Foundation
import Observation

/// The three AI runs nobody asks for.
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
/// **Getting to know you** — every few days, read back what the person has
/// actually said and update the picture of who they are. The reflection run
/// learns how they work from their records; this one learns what they care
/// about from their words, and it is the difference between a companion that
/// opens with the weather and one that opens with something you would want to
/// hear. It reads `read_conversations`, which deliberately cannot see the
/// unattended runs — including its own.
///
/// All three are off by default. The first two stage rather than write; this
/// one cannot, because memory is written directly by design, which is the
/// stronger reason to leave it opt-in. An unattended run that could edit the
/// database while you sleep is not a feature anyone asked for twice.
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
    /// Off by default like the others, and for a sharper reason: this is the
    /// one unattended run whose writes are not staged for review.
    var portraitEnabled: Bool {
        didSet {
            UserDefaults.standard.set(portraitEnabled, forKey: Key.portrait)
            restart()
        }
    }

    var nightlyHour: Int {
        didSet {
            UserDefaults.standard.set(nightlyHour, forKey: Key.nightlyHour)
            restart()
        }
    }

    private(set) var lastNightlyRun: Date?
    private(set) var lastReflectionRun: Date?
    private(set) var lastPortraitRun: Date?

    init(model: AppModel, session: AgentSession) {
        self.model = model
        self.session = session
        self.nightlyPlanEnabled = UserDefaults.standard.bool(forKey: Key.nightly)
        self.weeklyReflectionEnabled = UserDefaults.standard.bool(forKey: Key.reflection)
        self.portraitEnabled = UserDefaults.standard.bool(forKey: Key.portrait)
        let hour = UserDefaults.standard.integer(forKey: Key.nightlyHour)
        self.nightlyHour = (1...23).contains(hour) ? hour : 21
        self.lastNightlyRun = UserDefaults.standard.object(forKey: Key.lastNightly) as? Date
        self.lastReflectionRun = UserDefaults.standard.object(forKey: Key.lastReflection) as? Date
        self.lastPortraitRun = UserDefaults.standard.object(forKey: Key.lastPortrait) as? Date
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
            session.send(
                Self.nightlyPrompt(includingWorkItems: MeegleClient.configured() != nil),
                surface: .nightly
            )
            return
        }

        // Last of the three, and the only one that can wait. The other two are
        // about a particular day and miss their moment; this one just needs to
        // happen eventually, so it gives way rather than competing.
        if portraitEnabled, isPortraitDue(now: now), hasBeenSpokenTo(since: lastPortraitRun) {
            lastPortraitRun = now
            UserDefaults.standard.set(now, forKey: Key.lastPortrait)
            session.send(Self.portraitPrompt, surface: .portrait)
        }
    }

    /// Whether anything has actually been said since last time.
    ///
    /// Without it the run fires every third evening whatever happened, and a
    /// fortnight away from the desk buys five model calls that each conclude,
    /// separately, that nothing has changed. Asked in SQL rather than by
    /// letting the prompt find out, because finding out is the expensive part.
    func hasBeenSpokenTo(since: Date?) -> Bool {
        let cutoff = since ?? .distantPast
        let count = (try? model.database.writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM ai_run
                WHERE startedAt > ? AND status = ? AND surface NOT IN (?, ?, ?)
                """, arguments: [
                    cutoff, AIRun.Status.succeeded.rawValue,
                    AISurface.nightly.rawValue, AISurface.reflection.rawValue,
                    AISurface.portrait.rawValue
                ]) ?? 0
        }) ?? 0
        return count > 0
    }

    /// Every third evening. Often enough that a fortnight-old picture is the
    /// worst it gets; rare enough that it is not re-reading the same week over
    /// and over to reach the same conclusions.
    func isPortraitDue(
        now: Date = Date(),
        calendar: Calendar = .current,
        lastRun: Date?? = nil
    ) -> Bool {
        guard calendar.component(.hour, from: now) >= nightlyHour else { return false }
        guard let last = (lastRun ?? lastPortraitRun) else { return true }
        let days = calendar.dateComponents([.day], from: last, to: now).day ?? 0
        return days >= Self.portraitEveryDays
    }

    static let portraitEveryDays = 3

    /// Due after the chosen hour, once a day — and **not on the eve of a day
    /// the user does not work**.
    ///
    /// Found by running the thing: on a Saturday evening it plans Sunday, and
    /// with weekends excluded `find_free_slots` has nowhere to put anything, so
    /// the run costs a model call and produces a card that says it could do
    /// nothing. Two nights in seven, every week. Planning the next working day
    /// instead was the other option and is worse: a plan made on Friday for
    /// Monday is three days stale by the time it is read.
    /// `lastRun` is injectable for the same reason `worksTomorrow` is: without
    /// it the answer depends on `UserDefaults`, which a test shares with
    /// whatever the real app happens to have written this evening.
    func isNightlyDue(
        now: Date = Date(),
        calendar: Calendar = .current,
        worksTomorrow: Bool? = nil,
        lastRun: Date?? = nil
    ) -> Bool {
        guard calendar.component(.hour, from: now) >= nightlyHour else { return false }
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return false }
        let isWorkingDay = worksTomorrow
            ?? (Preferences.shared.workingHours(on: tomorrow, calendar: calendar) != nil)
        guard isWorkingDay else { return false }
        guard let last = lastRun ?? lastNightlyRun else { return true }
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
    /// The work-item step is present only when the connector is, matching the
    /// tool catalog and the system prompt.
    ///
    /// It relaxes "do not create tasks", and deliberately only that far. The
    /// original rule was there because a planner that quietly adds work loses
    /// trust in one night — but a ticket already assigned to this person is not
    /// invented work, it is work they are on the hook for whether or not they
    /// typed it in. The invention ban stands; what lifts is the ban on writing
    /// down something they are already committed to. Bounded to three so the
    /// morning's card is still something you can read over coffee.
    static func nightlyPrompt(includingWorkItems: Bool) -> String {
        let workItems = includingWorkItems ? """

            2. Call list_work_items with action "overdue", then "todo". Anything \
            marked alreadyInCadence is already here — for at most three of the \
            rest that genuinely matter tomorrow, use propose_create_task with \
            the externalID passed through, then schedule them like anything \
            else. Do not import the whole list; leave the ones that can wait.
            """ : ""

        return """
        Plan tomorrow. Do not invent work — everything you schedule must be \
        something I already have, either here or as a ticket assigned to me.

        1. Call get_schedule for tomorrow to see what is already committed.
        \(workItems)
        3. Call list_tasks for what is due or overdue.
        4. Call get_time_report for the last 7 days to see how much I actually \
        get through in a day, and do not schedule more than that.
        5. Call get_estimate_history for anything you are unsure about, and \
        trust it over the stated estimate.
        6. Use find_free_slots and propose_schedule for the few tasks that \
        matter most. Leave the day with room in it.

        Finish with explain: one short paragraph saying what you planned and \
        why, in plain language. If you brought anything in from a ticket, say \
        which — I should never find work here that I cannot place.
        """
    }

    /// The one that makes a companion out of a planner.
    ///
    /// Every rule under "What not to write down" is there because the obvious
    /// version of this prompt fails in that exact way: asked to summarise
    /// conversations, a model writes down *the conversations* — "asked about
    /// SwiftUI layout on Tuesday" — which is a diary, is never true a second
    /// time, and buries the four things about somebody that are.
    static let portraitPrompt = """
        Work out who I am, from what I have actually said to you.

        1. Call read_conversations for the last 14 days.
        2. Call search_memories before writing anything, so that you revise \
        rather than duplicate.
        3. Write down what those conversations show about me that will still be \
        true next month: what I am working on and why it matters to me, what I \
        keep coming back to, what I am plainly interested in away from the work, \
        how I like to be talked to, and anything I said I wanted to do and have \
        not done.
        4. Save each with remember. Use category "interest" for anything I care \
        about that is not work — that category exists so there is something \
        worth saying to me later, and it is the first thing lost if you only \
        file what bears on my schedule.
        5. Set source to "inferred". You worked these out; they should come back \
        for checking rather than standing forever.
        6. Reuse an existing key whenever this revises something you already \
        knew. Never leave two memories disagreeing.

        What NOT to write down:
        - What a conversation was about. "Asked about SwiftUI layout" is not a \
        fact about me. "Builds macOS apps in Swift" is, and you need it once.
        - Anything resting on a single passing remark. Twice is a pattern; once \
        is a Tuesday.
        - Anything about one task. That is what the task list is for.
        - Anything you would be uncomfortable repeating to me. If it is worth \
        knowing, it is worth being said out loud.

        Finish with one short line per memory you wrote or revised, so I can see \
        what you concluded about me. If you concluded nothing, say that in one \
        line — it is a normal answer to a quiet fortnight.
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
        remember with the same key; if it is simply no longer true, forget it.
        5. Call list_skills with staleOnly, and do the same for procedures: \
        confirm_skill if the steps still hold, save_skill with the same key if \
        they have drifted, forget_skill if the tool is gone. A procedure that \
        has quietly stopped working is worse than none, because it will be \
        followed.

        Steps 4 and 5 are the only run that revisits any of this, so whatever \
        you skip here goes another week unchecked.

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
        static let portrait = "portraitEnabled"
        static let lastPortrait = "portraitLastRun"
    }
}
