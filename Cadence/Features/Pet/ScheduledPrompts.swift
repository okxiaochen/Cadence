import Foundation
import Observation

/// Runs the saved questions that have a cadence, and decides when not to.
///
/// Three rules about *not* running, which matter more than the running:
///
/// - **Only when somebody is there.** A cadence that fires at an empty desk
///   spends a model call on an answer nobody reads, and then a second one on
///   the reply to the first.
/// - **Only when the assistant is free.** Two runs would fight over one CLI
///   process, and the one somebody actually asked for should win.
/// - **Only when there is something to say.** A prompt that reports "unchanged"
///   every two hours is how a companion stops being read, so a reply of `SKIP`
///   is silence rather than a message.
@MainActor
@Observable
final class ScheduledPrompts {

    /// The last thing worth saying, until it is dismissed or replaced.
    private(set) var announcement: String?
    private(set) var announcementTitle: String?

    private let preferences: Preferences
    private let session: AgentSession
    private let presence: PresenceTracker
    private var task: Task<Void, Never>?
    /// Which prompt is in flight, so its reply can be told apart from a reply
    /// to something the user typed.
    private var running: PetPrompt?
    private var messagesAtStart = 0

    init(preferences: Preferences, session: AgentSession, presence: PresenceTracker) {
        self.preferences = preferences
        self.session = session
        self.presence = presence
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                tick()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func dismiss() {
        announcement = nil
        announcementTitle = nil
    }

    /// One minute's worth of decision.
    func tick(now: Date = Date()) {
        collectReply()

        guard running == nil, !session.status.isRunning else { return }
        // An empty desk is the commonest reason not to bother.
        guard presence.sittingMinutes > 0 else { return }

        guard let due = preferences.petPrompts
            .filter({ $0.isUsable && $0.isScheduled })
            .first(where: { $0.isDue(now: now) })
        else { return }

        // Stamped before the run rather than after: a prompt that fails should
        // wait its turn again, not retry every minute.
        markRun(due, at: now)
        running = due
        messagesAtStart = session.messages.count
        session.send(Self.wrap(due.prompt), surface: .chat)
    }

    /// The instruction that makes silence possible. Appended rather than left
    /// to the user to remember, because forgetting it turns a cadence into a
    /// guarantee of noise.
    static func wrap(_ prompt: String) -> String {
        """
        \(prompt)

        This is a scheduled check that nobody asked for just now, so it has to \
        earn the interruption. Reply with one or two short sentences only if \
        there is something worth telling me. If there is nothing new, nothing \
        changed, or nothing worth reading, reply with exactly \
        \(PetPrompt.silence) and nothing else.
        """
    }

    private func collectReply() {
        guard let running, !session.status.isRunning else { return }
        defer { self.running = nil }

        guard session.messages.count > messagesAtStart,
              let reply = session.messages.last(where: { $0.role == .assistant && !$0.isError })?.text,
              !PetPrompt.isSilent(reply)
        else { return }

        announcementTitle = running.title
        announcement = reply
    }

    private func markRun(_ prompt: PetPrompt, at moment: Date) {
        guard let index = preferences.petPrompts.firstIndex(where: { $0.id == prompt.id })
        else { return }
        preferences.petPrompts[index].lastRunAt = moment
    }
}
